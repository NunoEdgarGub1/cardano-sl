{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

-- | Wallet web server.

module Pos.Wallet.Web.Server.Methods
       ( walletApplication
       , walletServer
       , walletServeImpl
       , walletServerOuts
       ) where

import           Control.Monad.Catch           (try)
import           Control.Monad.Except          (runExceptT)
import           Control.Monad.Trans.State     (get, runStateT)
import qualified Data.ByteString.Base64        as B64
import           Data.Default                  (Default, def)
import           Data.List                     (elemIndex, nub, (!!))
import           Data.Time.Clock.POSIX         (POSIXTime, getPOSIXTime)
import           Formatting                    (build, ords, sformat, stext, (%))
import           Network.Wai                   (Application)
import           Servant.API                   ((:<|>) ((:<|>)),
                                                FromHttpApiData (parseUrlPiece))
import           Servant.Server                (Handler, Server, ServerT, serve)
import           Servant.Utils.Enter           ((:~>) (..), enter)
import           System.Wlog                   (logInfo)
import           Universum

import           Pos.Aeson.ClientTypes         ()
import           Pos.Communication.Protocol    (OutSpecs, SendActions, hoistSendActions)
import           Pos.Constants                 (curSoftwareVersion)
import           Pos.Crypto                    (hash)
import           Pos.Crypto                    (deterministicKeyGen, toPublic)
import           Pos.DHT.Model                 (getKnownPeers)
import           Pos.Slotting                  (getSlotDuration)
import           Pos.Types                     (Address, ApplicationName, BlockVersion,
                                                ChainDifficulty (..), Coin,
                                                NumSoftwareVersion, SoftwareVersion,
                                                TxOut (..), addressF, coinF,
                                                decodeTextAddress, makePubKeyAddress,
                                                mkCoin)
import           Pos.Types.Version             (ApplicationName (..), BlockVersion (..),
                                                SoftwareVersion (..))
import           Pos.Util                      (maybeThrow)
import           Pos.Util.BackupPhrase         (BackupPhrase, keysFromPhrase)
import           Pos.Wallet.KeyStorage         (KeyError (..), MonadKeys (..),
                                                addSecretKey)
import           Pos.Wallet.Tx                 (sendTxOuts, submitTx)
import           Pos.Wallet.Tx.Pure            (TxHistoryEntry (..))
import           Pos.Wallet.WalletMode         (WalletMode, applyLastUpdate, getBalance,
                                                getTxHistory, localChainDifficulty,
                                                networkChainDifficulty, waitForUpdate)
import           Pos.Wallet.Web.Api            (WalletApi, walletApi)
import           Pos.Wallet.Web.ClientTypes    (CAddress, CCurrency (ADA), CProfile,
                                                CProfile (..), CTx, CTxId, CTxMeta (..),
                                                CUpdateInfo (..), CWallet (..),
                                                CWalletInit (..), CWalletMeta (..),
                                                CWalletRedeem (..), NotifyEvent (..),
                                                addressToCAddress, cAddressToAddress,
                                                mkCTx, mkCTxId, toCUpdateInfo,
                                                txContainsTitle, txIdToCTxId)
import           Pos.Wallet.Web.Error          (WalletError (..))
import           Pos.Wallet.Web.Server.Sockets (MonadWalletWebSockets (..),
                                                WalletWebSockets, closeWSConnection,
                                                getWalletWebSocketsState,
                                                initWSConnection, notify, runWalletWS,
                                                upgradeApplicationWS)
import           Pos.Wallet.Web.State          (MonadWalletWebDB (..), WalletWebDB,
                                                addOnlyNewTxMeta, addUpdate, closeState,
                                                createWallet, getNextUpdate,
                                                getPostponeUpdateUntil, getProfile,
                                                getTxMeta, getWalletMeta, getWalletState,
                                                openState, removeNextUpdate,
                                                removePostponeUpdateUntil, removeWallet,
                                                runWalletWebDB, setPostponeUpdateUntil,
                                                setProfile, setWalletMeta,
                                                setWalletTransactionMeta)
import           Pos.Web.Server                (serveImpl)

----------------------------------------------------------------------------
-- Top level functionality
----------------------------------------------------------------------------

type WalletWebHandler m = WalletWebSockets (WalletWebDB m)

type WalletWebMode ssc m
    = ( WalletMode ssc m
      , MonadWalletWebDB m
      , MonadWalletWebSockets m
      )

walletServeImpl
    :: ( MonadIO m
       , MonadMask m
       , WalletWebMode ssc (WalletWebHandler m))
    => WalletWebHandler m Application     -- ^ Application getter
    -> FilePath                        -- ^ Path to wallet acid-state
    -> Bool                            -- ^ Rebuild flag for acid-state
    -> Word16                          -- ^ Port to listen
    -> m ()
walletServeImpl app daedalusDbPath dbRebuild port =
    bracket
        ((,) <$> openDB <*> initWS)
        (\(db, conn) -> closeDB db >> closeWS conn)
        $ \(db, conn) ->
            serveImpl (runWalletWebDB db $ runWalletWS conn app) port
  where openDB = openState dbRebuild daedalusDbPath
        closeDB = closeState
        initWS = initWSConnection
        closeWS = closeWSConnection

walletApplication
    :: WalletWebMode ssc m
    => m (Server WalletApi)
    -> m Application
walletApplication serv = do
    wsConn <- getWalletWebSockets
    serv >>= return . upgradeApplicationWS wsConn . serve walletApi

walletServer
    :: (Monad m, WalletWebMode ssc (WalletWebHandler m))
    => SendActions m
    -> WalletWebHandler m (WalletWebHandler m :~> Handler)
    -> WalletWebHandler m (Server WalletApi)
walletServer sendActions nat = do
    whenM (isNothing <$> getProfile) $
        createUserProfile >>= setProfile
    ws    <- lift getWalletState
    socks <- getWalletWebSocketsState
    let sendActions' = hoistSendActions
            (lift . lift)
            (runWalletWebDB ws . runWalletWS socks)
            sendActions
    nat >>= launchNotifier
    myCAddresses >>= mapM_ insertAddressMeta
    (`enter` servantHandlers sendActions') <$> nat
  where
    insertAddressMeta cAddr =
        getWalletMeta cAddr >>= createWallet cAddr . fromMaybe def
    createUserProfile = do
        time <- liftIO getPOSIXTime
        pure $ CProfile mempty mempty mempty mempty time mempty mempty

------------------------
-- Notifier
------------------------

data SyncProgress =
    SyncProgress { spLocalCD   :: ChainDifficulty
                 , spNetworkCD :: ChainDifficulty
                 }

instance Default SyncProgress where
    def = let chainDef = ChainDifficulty 0 in SyncProgress chainDef chainDef

-- type SyncState = StateT SyncProgress

-- FIXME: this is really inaficient. Temporary solution
launchNotifier :: WalletWebMode ssc m => (m :~> Handler) -> m ()
launchNotifier nat = void . liftIO $ mapM startForking
    [ dificultyNotifier
    , updateNotifier
    , updateNotifierUnPostpone
    ]
  where
    cooldownPeriod = 5000000         -- 5 sec
    cooldownPostponePeriod = 5000000 -- 5 sec
    mockupUpdatePeriod = 10000000    -- 10 sec
    difficultyNotifyPeriod = 500000  -- 0.5 sec
    forkForever action = forkFinally action $ const $ do
        -- TODO: log error
        -- cooldown
        threadDelay cooldownPeriod
        void $ forkForever action
    -- TODO: use Servant.enter here
    -- FIXME: don't ignore errors, send error msg to the socket
    startForking = forkForever . void . runExceptT . unNat nat
    notifier period action = forever $ do
        liftIO $ threadDelay period
        action
    dificultyNotifier = void . flip runStateT def $ notifier difficultyNotifyPeriod $ do
        networkDifficulty <- networkChainDifficulty
        -- TODO: use lenses!
        whenM ((networkDifficulty /=) . spNetworkCD <$> get) $ do
            lift $ notify $ NetworkDifficultyChanged networkDifficulty
            modify $ \sp -> sp { spNetworkCD = networkDifficulty }

        localDifficulty <- localChainDifficulty
        whenM ((localDifficulty /=) . spLocalCD <$> get) $ do
            lift $ notify $ LocalDifficultyChanged localDifficulty
            modify $ \sp -> sp { spLocalCD = localDifficulty }
    updateNotifier = notifier mockupUpdatePeriod $
        whenNothingM_ getPostponeUpdateUntil $
            liftIO getPOSIXTime >>= setPostponeUpdateUntil
    updateNotifierUnPostpone = notifier cooldownPostponePeriod $ do
        mPostpone <- getPostponeUpdateUntil
        time <- liftIO getPOSIXTime
        when (((<) <$> mPostpone <*> pure time) == Just True) $ do
            notify UpdateAvailable
            removePostponeUpdateUntil

    -- historyNotifier :: WalletWebMode ssc m => m ()
    -- historyNotifier = do
    --     cAddresses <- myCAddresses
    --     forM_ cAddresses $ \cAddress -> do
    --         -- TODO: is reading from acid RAM only (not reading from disk?)
    --         oldHistoryLength <- length . fromMaybe mempty <$> getWalletHistory cAddress
    --         newHistoryLength <- length <$> getHistory cAddress
    --         when (oldHistoryLength /= newHistoryLength) .
    --             notify $ NewWalletTransaction cAddress

walletServerOuts :: OutSpecs
walletServerOuts = sendTxOuts

----------------------------------------------------------------------------
-- Handlers
----------------------------------------------------------------------------

servantHandlers :: WalletWebMode ssc m =>  SendActions m -> ServerT WalletApi m
servantHandlers sendActions =
     (catchWalletError . getWallet)
    :<|>
     catchWalletError getWallets
    :<|>
     (\a b -> catchWalletError . send sendActions a b)
    :<|>
     (\a b c d e -> catchWalletError . sendExtended sendActions a b c d e)
    :<|>
     (\a b -> catchWalletError . getHistory a b )
    :<|>
     (\a b c -> catchWalletError . searchHistory a b c)
    :<|>
     (\a b -> catchWalletError . updateTransaction a b)
    :<|>
     catchWalletError . newWallet
    :<|>
     catchWalletError . restoreWallet
    :<|>
     (\a -> catchWalletError . updateWallet a)
    :<|>
     catchWalletError . deleteWallet
    :<|>
     (\a -> catchWalletError . isValidAddress a)
    :<|>
     catchWalletError getUserProfile
    :<|>
     catchWalletError . updateUserProfile
    :<|>
     catchWalletError . redeemADA sendActions
    :<|>
     catchWalletError nextUpdate
    :<|>
     catchWalletError applyUpdate
    :<|>
     catchWalletError blockchainSlotDuration
    :<|>
     catchWalletError (pure curSoftwareVersion)
    :<|>
     catchWalletError . postponeUpdatesUntil
  where
    -- TODO: can we with Traversable map catchWalletError over :<|>
    -- TODO: add logging on error
    catchWalletError = try

-- getAddresses :: WalletWebMode ssc m => m [CAddress]
-- getAddresses = map addressToCAddress <$> myAddresses

-- getBalances :: WalletWebMode ssc m => m [(CAddress, Coin)]
-- getBalances = join $ mapM gb <$> myAddresses
--   where gb addr = (,) (addressToCAddress addr) <$> getBalance addr

getUserProfile :: WalletWebMode ssc m => m CProfile
getUserProfile = getProfile >>= maybe noProfile pure
  where
    noProfile = throwM $ Internal "No user profile"

updateUserProfile :: WalletWebMode ssc m => CProfile -> m CProfile
updateUserProfile profile = setProfile profile >> getUserProfile

getWallet :: WalletWebMode ssc m => CAddress -> m CWallet
getWallet cAddr = do
    balance <- getBalance =<< decodeCAddressOrFail cAddr
    meta <- getWalletMeta cAddr >>= maybe noWallet pure
    pure $ CWallet cAddr balance meta
  where
    noWallet = throwM . Internal $
        sformat ("No wallet with address "%build%" is found") cAddr

-- TODO: probably poor naming
decodeCAddressOrFail :: WalletWebMode ssc m => CAddress -> m Address
decodeCAddressOrFail = either wrongAddress pure . cAddressToAddress
  where wrongAddress err = throwM . Internal $
            sformat ("Error while decoding CAddress: "%stext) err

getWallets :: WalletWebMode ssc m => m [CWallet]
getWallets = join $ mapM getWallet <$> myCAddresses

send :: WalletWebMode ssc m =>  SendActions m -> CAddress -> CAddress -> Coin -> m CTx
send sendActions srcCAddr dstCAddr c =
    sendExtended sendActions srcCAddr dstCAddr c ADA mempty mempty

sendExtended :: WalletWebMode ssc m => SendActions m -> CAddress -> CAddress -> Coin -> CCurrency -> Text -> Text -> m CTx
sendExtended sendActions srcCAddr dstCAddr c curr title desc = do
    srcAddr <- decodeCAddressOrFail srcCAddr
    dstAddr <- decodeCAddressOrFail dstCAddr
    idx <- getAddrIdx srcAddr
    sks <- getSecretKeys
    let sk = sks !! idx
    na <- getKnownPeers
    etx <- submitTx sendActions sk na [(TxOut dstAddr c, [])]
    case etx of
        Left err -> throwM . Internal $ sformat ("Cannot send transaction: "%stext) err
        Right (tx, _, _) -> do
            logInfo $
                sformat ("Successfully sent "%coinF%" from "%ords%" address to "%addressF)
                c idx dstAddr
            -- TODO: this should be removed in production
            let txHash = hash tx
            () <$ addHistoryTx dstCAddr curr title desc (THEntry txHash tx False Nothing)
            addHistoryTx srcCAddr curr title desc (THEntry txHash tx True Nothing)

getHistory :: WalletWebMode ssc m => CAddress -> Word -> Word -> m ([CTx], Word)
getHistory cAddr skip limit = do
    history <- getTxHistory =<< decodeCAddressOrFail cAddr
    cHistory <- mapM (addHistoryTx cAddr ADA mempty mempty) history
    pure (paginate cHistory, fromIntegral $ length cHistory)
  where
    paginate = take (fromIntegral limit) . drop (fromIntegral skip)

-- FIXME: is Word enough for length here?
searchHistory :: WalletWebMode ssc m => CAddress -> Text -> Word -> Word -> m ([CTx], Word)
searchHistory cAddr search skip limit = first (filter $ txContainsTitle search) <$> getHistory cAddr skip limit

addHistoryTx
    :: WalletWebMode ssc m
    => CAddress
    -> CCurrency
    -> Text
    -> Text
    -> TxHistoryEntry
    -> m CTx
addHistoryTx cAddr curr title desc wtx@(THEntry txId _ _ _) = do
    -- TODO: this should be removed in production
    diff <- networkChainDifficulty
    addr <- decodeCAddressOrFail cAddr
    meta <- CTxMeta curr title desc <$> liftIO getPOSIXTime
    let cId = txIdToCTxId txId
    addOnlyNewTxMeta cAddr cId meta
    meta' <- maybe meta identity <$> getTxMeta cAddr cId
    return $ mkCTx addr diff wtx meta'

newWallet :: WalletWebMode ssc m => CWalletInit -> m CWallet
newWallet CWalletInit {..} = do
    cAddr <- genSaveAddress cwBackupPhrase
    createWallet cAddr cwInitMeta
    getWallet cAddr

restoreWallet :: WalletWebMode ssc m => CWalletInit -> m CWallet
restoreWallet CWalletInit {..} = do
    cAddr <- genSaveAddress cwBackupPhrase
    getWalletMeta cAddr >>= maybe (createWallet cAddr cwInitMeta) (const walletExistsError)
    getWallet cAddr
  where
    walletExistsError = throwM $ Internal "Wallet with that mnemonics already exists"

updateWallet :: WalletWebMode ssc m => CAddress -> CWalletMeta -> m CWallet
updateWallet cAddr wMeta = do
    setWalletMeta cAddr wMeta
    getWallet cAddr

updateTransaction :: WalletWebMode ssc m => CAddress -> CTxId -> CTxMeta -> m ()
updateTransaction = setWalletTransactionMeta

deleteWallet :: WalletWebMode ssc m => CAddress -> m ()
deleteWallet cAddr = do
    deleteAddress =<< decodeCAddressOrFail cAddr
    removeWallet cAddr
  where
    deleteAddress addr = do
        idx <- getAddrIdx addr
        deleteSecretKey (fromIntegral idx) `catch` deleteErrHandler
    deleteErrHandler (PrimaryKey err) = throwM . Internal $
        sformat ("Error while deleting wallet: "%stext) err

-- NOTE: later we will have `isValidAddress :: CCurrency -> CAddress -> m Bool` which should work for arbitrary crypto
isValidAddress :: WalletWebMode ssc m => CCurrency -> Text -> m Bool
isValidAddress ADA sAddr = pure . either (const False) (const True) $ decodeTextAddress sAddr
isValidAddress _ _       = pure False

-- | Get last update info
nextUpdate :: WalletWebMode ssc m => m CUpdateInfo
nextUpdate = pure $
    CUpdateInfo
        (SoftwareVersion (ApplicationName "this is faked update") 0)
        (BlockVersion 0 0 0)
        0
        False
        0
        0
        (mkCoin 0)
        (mkCoin 0)

applyUpdate :: WalletWebMode ssc m => m ()
applyUpdate = removeNextUpdate >> applyLastUpdate

blockchainSlotDuration :: WalletWebMode ssc m => m Word
blockchainSlotDuration = fromIntegral <$> getSlotDuration

redeemADA :: WalletWebMode ssc m => SendActions m -> CWalletRedeem -> m CWallet
redeemADA sendActions CWalletRedeem {..} = do
    seedBs <- either
        (\e -> throwM $ Internal ("Seed is invalid base64 string: " <> toText e))
        pure $ B64.decode (encodeUtf8 crSeed)
    (redeemPK, redeemSK) <- maybeThrow (Internal "Seed is not 32-byte long") $
                            deterministicKeyGen seedBs
    -- new redemption wallet
    walletB <- getWallet crWalletId

    -- send from seedAddress to walletB
    let dstCAddr = cwAddress walletB
    dstAddr <- decodeCAddressOrFail dstCAddr
    redeemBalance <- getBalance $ makePubKeyAddress redeemPK
    na <- getKnownPeers
    etx <- submitTx sendActions redeemSK na [(TxOut dstAddr redeemBalance, [])]
    case etx of
        Left err -> throwM . Internal $ "Cannot send redemption transaction: " <> err
        Right (tx, _, _) -> do
            -- add redemption transaction to the history of new wallet
            () <$ addHistoryTx dstCAddr ADA "ADA redemption" ""
                (THEntry (hash tx) tx False Nothing)
            pure walletB

postponeUpdatesUntil :: WalletWebMode ssc m => POSIXTime -> m ()
postponeUpdatesUntil = setPostponeUpdateUntil

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

myAddresses :: MonadKeys m => m [Address]
myAddresses = nub . map (makePubKeyAddress . toPublic) <$> getSecretKeys

myCAddresses :: MonadKeys m => m [CAddress]
myCAddresses = map addressToCAddress <$> myAddresses

getAddrIdx :: WalletWebMode ssc m => Address -> m Int
getAddrIdx addr = elemIndex addr <$> myAddresses >>= maybe notFound pure
  where notFound = throwM . Internal $
            sformat ("Address "%addressF%" is not found in wallet") $ addr

genSaveAddress :: WalletWebMode ssc m => BackupPhrase -> m CAddress
genSaveAddress ph = addressToCAddress . makePubKeyAddress . toPublic <$> genSaveSK ph
  where
    genSaveSK ph' = do
        let sk = fst $ keysFromPhrase ph'
        addSecretKey sk
        return sk


----------------------------------------------------------------------------
-- Orphan instances
----------------------------------------------------------------------------

instance FromHttpApiData Coin where
    parseUrlPiece = fmap mkCoin . parseUrlPiece

instance FromHttpApiData Address where
    parseUrlPiece = decodeTextAddress

instance FromHttpApiData CAddress where
    parseUrlPiece = fmap addressToCAddress . decodeTextAddress

-- FIXME: unsafe (temporary, will be removed probably in future)
-- we are not checking is receaved Text really vald CTxId
instance FromHttpApiData CTxId where
    parseUrlPiece = pure . mkCTxId

instance FromHttpApiData CCurrency where
    parseUrlPiece = first fromString . readEither . toString
