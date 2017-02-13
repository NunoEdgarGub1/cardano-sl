{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent.STM.TVar (modifyTVar', newTVarIO, readTVarIO)
import           Control.Lens                (view, _1)
import qualified Data.List.NonEmpty          as NA
import           Data.Maybe                  (fromJust, fromMaybe)
import           Data.Proxy                  (Proxy (..))
import           Data.Time.Clock.POSIX       (getPOSIXTime)
import           Data.Time.Units             (Microsecond)
import           Formatting                  (float, int, sformat, (%))
import           Mockable                    (Production, delay, forConcurrently, fork)
import           Node                        (Listener, ListenerAction (..), SendActions,
                                              hoistListenerAction, hoistSendActions)
import           Options.Applicative         (execParser)
import           Serokell.Util.Verify        (VerificationRes (..))
import           System.FilePath.Posix       ((</>))
import           System.Random.Shuffle       (shuffleM)
import           System.Wlog                 (logInfo)
import           Test.QuickCheck             (arbitrary, generate)
import           Universum                   hiding (forConcurrently)

import qualified Pos.CLI                     as CLI
import           Pos.Communication           (BiP, allListeners)
import           Pos.Constants               (genesisN, neighborsSendThreshold,
                                              slotDuration, slotSecurityParam)
import           Pos.Crypto                  (KeyPair (..), hash)
import           Pos.DHT.Model               (DHTNodeType (..), MonadDHT, dhtAddr,
                                              discoverPeers, getKnownPeers,
                                              nodeIdToAddress, sendToNode)
import           Pos.Genesis                 (genesisUtxo)
import           Pos.Launcher                (BaseParams (..), LoggingParams (..),
                                              NodeParams (..), RealModeResources,
                                              bracketResources, initLrc, runNode,
                                              runRawRealMode, runTimeSlaveReal,
                                              stakesDistr)
import           Pos.Ssc.Class               (SscConstraint, SscParams)
import           Pos.Ssc.GodTossing          (GtParams (..), SscGodTossing)
import           Pos.Ssc.NistBeacon          (SscNistBeacon)
import           Pos.Ssc.SscAlgo             (SscAlgo (..))
import           Pos.Statistics              (getNoStatsT)
import           Pos.Txp.Types               (TxMsgTag (..))
import           Pos.Types                   (TxAux, TxId)
import           Pos.Util.JsonLog            ()
import           Pos.Util.Relay              (MempoolInvMsg (..), MempoolMsg (..))
import           Pos.Util.TimeWarp           (NetworkAddress, ms, sec)
import           Pos.Util.UserSecret         (simpleUserSecret)
import           Pos.Wallet                  (submitTxRaw)
import           Pos.WorkMode                (ProductionMode)

import           GenOptions                  (GenOptions (..), optsInfo)
import           TxAnalysis                  (checkWorker, createTxTimestamps,
                                              registerSentTx)
import           TxGeneration                (BambooPool, MempoolStorage, addToMpStorage,
                                              createBambooPool, createMempoolStorage,
                                              curBambooTx, initTransaction, isTxVerified,
                                              nextValidTx, resetBamboo)

import           Util


-- | Resend initTx with `slotDuration` period until it's verified
seedInitTx :: forall ssc . SscConstraint ssc
           => SendActions BiP (ProductionMode ssc)
           -> Double
           -> BambooPool
           -> TxAux
           -> ProductionMode ssc ()
seedInitTx sendActions recipShare bp initTx = do
    na <- getPeers recipShare
    logInfo "Issuing seed transaction"
    submitTxRaw sendActions na initTx
    logInfo "Waiting for 1 slot before resending..."
    delay slotDuration
    -- If next tx is present in utxo, then everything is all right
    tx <- liftIO $ curBambooTx bp 1
    isVer <- isTxVerified $ view _1 tx
    if isVer
        then pure ()
        else seedInitTx sendActions recipShare bp initTx

chooseSubset :: Double -> [a] -> [a]
chooseSubset share ls = take n ls
  where n = max 1 $ round $ share * fromIntegral (length ls)

getPeers :: (MonadDHT m, MonadIO m)
         => Double -> m [NetworkAddress]
getPeers share = do
    peers <- fmap dhtAddr <$> do
        ps <- getKnownPeers
        if length ps < neighborsSendThreshold
           then discoverPeers DHTFull
           else return ps
    liftIO $ chooseSubset share <$> shuffleM peers

mempoolPolling :: WorkMode ssc m => SendActions BiP m -> MempoolStorage -> m ()
mempoolPolling sendActions ms = do
    na <- getPeers 1
    let msg = MempoolMsg TxMsgTag
    forM_ na $ \addr -> sendToNode sendActions addr msg
    delay $ sec 20

mempoolListener :: WorkMode ssc m => MempoolStorage -> Listener BiP m
mempoolListener ms = ListenerActionOneMsg $ \peerId sendActions (mi :: MempoolInvMsg TxId TxMsgTag) -> do
    let na = fromJust $ nodeIdToAddress peerId
    addToMpStorage ms na $ NA.toList $ mimKeys mi

runSGMode
    :: forall ssc a .
       (SscConstraint ssc)
    => Maybe MempoolStorage
    -> RealModeResources
    -> NodeParams
    -> SscParams ssc
    -> (SendActions BiP (ProductionMode ssc) -> ProductionMode ssc a)
    -> Production a
runSGMode mms res np@NodeParams {..} sscnp action =
    runRawRealMode res np sscnp listeners $
    \sendActions -> getNoStatsT . action $ hoistSendActions lift getNoStatsT sendActions
  where
    listeners = hoistListenerAction getNoStatsT lift <$> allListeners ++ mempoolLs
    mempoolLs = case mms of
        Nothing -> []
        Just ms -> [mempoolListener ms]

runSmartGen
    :: forall ssc . SscConstraint ssc
    => Maybe MempoolStorage
    -> RealModeResources
    -> NodeParams
    -> SscParams ssc
    -> GenOptions
    -> Production ()
runSmartGen mms res np@NodeParams{..} sscnp opts@GenOptions{..} =
  runSGMode mms res np sscnp $ \sendActions -> do
    -- initLrc
    let getPosixMs = round . (*1000) <$> liftIO getPOSIXTime
        initTx = initTransaction opts

    bambooPools <- forM goGenesisIdxs $ \(fromIntegral -> i) ->
        liftIO $ createBambooPool goMOfNParams i $ initTx i

    -- | Start mempool polling
    case mms of
        Nothing -> pure ()
        Just ms -> void $ fork $ mempoolPolling sendActions ms

    txTimestamps <- liftIO createTxTimestamps

    -- | Run all the usual node workers in order to get
    -- access to blockchain
    void $ fork $ runNode @ssc [] sendActions

    let logsFilePrefix = fromMaybe "." (CLI.logPrefix goCommonArgs)
    -- | Run the special worker to check new blocks and
    -- fill tx verification times
    void $ fork $ checkWorker txTimestamps logsFilePrefix

    logInfo "STARTING TXGEN"

    let forFold init ls act = foldM act init ls

    -- [CSL-220] Write MonadBaseControl instance for KademliaDHT
    -- Seeding init tx
    _ <- forConcurrently (zip bambooPools goGenesisIdxs) $ \(pool, fromIntegral -> idx) ->
            seedInitTx sendActions goRecipientShare pool (initTx idx)

    -- Start writing tps file
    liftIO $ writeFile (logsFilePrefix </> tpsCsvFile) tpsCsvHeader

    let phaseDurationMs = fromIntegral (slotSecurityParam + goPropThreshold) * slotDuration
        roundDurationSec = fromIntegral (goRoundPeriodRate + 1) *
                           fromIntegral (phaseDurationMs `div` sec 1)

    void $ forFold (goInitTps, goTpsIncreaseStep) [1 .. goRoundNumber] $
        \(goTPS', increaseStep) (roundNum :: Int) -> do
        -- Start writing verifications file
        liftIO $ writeFile (logsFilePrefix </> verifyCsvFile roundNum) verifyCsvHeader


        let goTPS = goTPS' / fromIntegral (length bambooPools)
            tpsDelta = round $ 1000 / goTPS
            txNum = round $ roundDurationSec * goTPS

        logInfo $ sformat ("Round "%int%" from "%int%": TPS "%float)
            roundNum goRoundNumber goTPS

        realTxNum <- liftIO $ newTVarIO (0 :: Int)

        -- Make a pause between rounds
        delay (round $ goRoundPause * fromIntegral (sec 1) :: Microsecond)

        beginT <- getPosixMs
        let startMeasurementsT =
                beginT + fromIntegral (phaseDurationMs `div` ms 1)

        let sendThread bambooPool = do
              logInfo $ sformat ("CURRENT TXNUM: "%int) txNum
              forM_ [0 .. txNum - 1] $ \(idx :: Int) -> do
                  preStartT <- getPosixMs
                  -- prevent periods longer than we expected
                  unless (preStartT - beginT > round (roundDurationSec * 1000)) $ do
                      startT <- getPosixMs

                      -- Get a random subset of neighbours to send tx
                      na <- getPeers goRecipientShare

                      eTx <- nextValidTx bambooPool mms goTPS goPropThreshold
                      case eTx of
                          Left parent -> do
                              logInfo $ sformat ("Transaction #"%int%" is not verified yet!") idx
                              logInfo "Resend the transaction parent again"
                              submitTxRaw sendActions na parent

                          Right (transaction, witness, distr) -> do
                              let curTxId = hash transaction
                              logInfo $ sformat ("Sending transaction #"%int) idx
                              submitTxRaw sendActions na (transaction, witness, distr)
                              when (startT >= startMeasurementsT) $ liftIO $ do
                                  liftIO $ atomically $ modifyTVar' realTxNum (+1)
                                  -- put timestamp to current txmap
                                  registerSentTx txTimestamps curTxId roundNum $ fromIntegral startT * 1000

                      endT <- getPosixMs
                      let runDelta = endT - startT
                      delay $ ms (max 0 $ tpsDelta - runDelta)
              liftIO $ resetBamboo bambooPool

        -- [CSL-220] Write MonadBaseControl instance for KademliaDHT
        _ <- forConcurrently bambooPools sendThread
        finishT <- getPosixMs

        realTxNumVal <- liftIO $ readTVarIO realTxNum

        let globalTime, realTPS :: Double
            globalTime = (fromIntegral (finishT - startMeasurementsT)) / 1000
            realTPS = (fromIntegral realTxNumVal) / globalTime
            (newTPS, newStep) = if realTPS >= goTPS' - 5
                                then (goTPS' + increaseStep, increaseStep)
                                else if realTPS >= goTPS' * 0.8
                                     then (goTPS', increaseStep)
                                     else (realTPS, increaseStep / 2)

        putText "----------------------------------------"
        putText $ "Sending transactions took (s): " <> show globalTime
        putText $ "So real tps was: " <> show realTPS

        -- We collect tables of really generated tps
        liftIO $ appendFile (logsFilePrefix </> tpsCsvFile) $
            tpsCsvFormat (globalTime, (goTPS, length bambooPools), realTPS)

        -- Wait for 1 phase (to get all the last sent transactions)
        logInfo "Pausing transaction spawning for 1 phase"
        delay phaseDurationMs

        return (newTPS, newStep)

-----------------------------------------------------------------------------
-- Main
-----------------------------------------------------------------------------

main :: IO ()
main = do
    opts@GenOptions {..} <- execParser optsInfo

    -- Check correctness of --m-of-n param
    case goMOfNParams of
        Nothing -> return ()
        Just (m, n) -> if m > n || n > genesisN
                       then panic "Invalid `--m-of-n` value"
                       else return ()

    KeyPair _ sk <- generate arbitrary
    vssKeyPair <- generate arbitrary
    let logParams =
            LoggingParams
            { lpRunnerTag     = "smart-gen"
            , lpHandlerPrefix = CLI.logPrefix goCommonArgs
            , lpConfigPath    = CLI.logConfig goCommonArgs
            }
        baseParams =
            BaseParams
            { bpLoggingParams      = logParams
            , bpIpPort             = goIpPort
            , bpDHTPeers           = CLI.dhtPeers goCommonArgs
            , bpDHTKeyOrType       = Right DHTClient
            , bpDHTExplicitInitial = CLI.dhtExplicitInitial goCommonArgs
            }

    bracketResources baseParams $ \res -> do
        let timeSlaveParams =
                baseParams
                { bpLoggingParams = logParams { lpRunnerTag = "time-slave" }
                }

        systemStart <- case CLI.sscAlgo goCommonArgs of
            GodTossingAlgo -> runTimeSlaveReal (Proxy :: Proxy SscGodTossing) res timeSlaveParams
            NistBeaconAlgo -> runTimeSlaveReal (Proxy :: Proxy SscNistBeacon) res timeSlaveParams

        let params =
                NodeParams
                { npDbPathM       = "rocks-smartwallet"
                , npRebuildDb     = True
                , npSystemStart   = systemStart
                , npSecretKey     = sk
                , npUserSecret    = simpleUserSecret sk "smartgen-secret.sk"
                , npBaseParams    = baseParams
                , npCustomUtxo    = genesisUtxo $
                                        stakesDistr
                                        (CLI.flatDistr goCommonArgs)
                                        (CLI.bitcoinDistr goCommonArgs)
                                        (CLI.expDistr goCommonArgs)
                , npTimeLord      = False
                , npJLFile        = goJLFile
                , npAttackTypes   = []
                , npAttackTargets = []
                , npPropagation   = not (CLI.disablePropagation goCommonArgs)
                }
            gtParams =
                GtParams
                { gtpRebuildDb  = True
                , gtpSscEnabled = False
                , gtpVssKeyPair = vssKeyPair
                }

        mms <- if goMempoolCheck
               then Just <$> createMempoolStorage []
               else return Nothing

        case CLI.sscAlgo goCommonArgs of
            GodTossingAlgo -> putText "Using MPC coin tossing" *>
                              runSmartGen @SscGodTossing mms res params gtParams opts
            NistBeaconAlgo -> putText "Using NIST beacon" *>
                              runSmartGen @SscNistBeacon mms res params () opts
