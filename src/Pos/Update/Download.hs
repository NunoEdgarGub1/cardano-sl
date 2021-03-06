-- | Logic related to downloading update.

module Pos.Update.Download
       ( downloadUpdate
       , downloadHash
       ) where

import           Control.Concurrent.MVar (putMVar)
import qualified Data.ByteArray          as BA
import qualified Data.ByteString.Lazy    as BSL
import qualified Data.HashMap.Strict     as HM
import qualified Data.Text               as T
import           Formatting              (build, sformat, stext, (%))
import           Network.HTTP.Client     (Manager, newManager)
import           Network.HTTP.Client.TLS (tlsManagerSettings)
import           Network.HTTP.Simple     (getResponseBody, getResponseStatus,
                                          getResponseStatusCode, httpLBS, parseRequest,
                                          setRequestManager)
import qualified Serokell.Util.Base16    as B16
import           Serokell.Util.Text      (listJsonIndent)
import           System.Directory        (doesFileExist)
import           System.Wlog             (logDebug, logInfo, logWarning)
import           Universum

import           Pos.Constants           (appSystemTag)
import           Pos.Context             (getNodeContext, ncNodeParams, ncUpdateSemaphore,
                                          npUpdatePath, npUpdateServers, npUpdateWithPkg)
import           Pos.Crypto              (Hash, castHash, hash)
import           Pos.Update.Core.Types   (UpdateData (..), UpdateProposal (..))
import           Pos.Update.Poll.Types   (ConfirmedProposalState (..))
import           Pos.Util                ((<//>))
import           Pos.WorkMode            (WorkMode)

showHash :: Hash a -> FilePath
showHash = toString . B16.encode . BA.convert

-- | Download and save archive update by given `ConfirmedProposalState`
downloadUpdate :: WorkMode ssc m => ConfirmedProposalState -> m ()
downloadUpdate cst@ConfirmedProposalState {..} = do
    logDebug "Update downloading triggered"
    useInstaller <- npUpdateWithPkg . ncNodeParams <$> getNodeContext
    updateServers <- npUpdateServers . ncNodeParams <$> getNodeContext
    let dataHash = if useInstaller then udPkgHash else udAppDiffHash
        mupdHash = castHash . dataHash <$>
                   HM.lookup appSystemTag (upData cpsUpdateProposal)
    case mupdHash of
        Nothing -> logInfo "This update is not for our system"
        Just updHash -> do
            updPath <- npUpdatePath . ncNodeParams <$> getNodeContext
            -- let updAppName = svAppName . upSoftwareVersion $
            --                  cpsUpdateProposal
            unlessM (liftIO $ doesFileExist updPath) $ do
                logInfo "Downloading update..."
                efile <- liftIO $ downloadHash updateServers updHash
                case efile of
                    Left err -> logWarning $
                        sformat ("Update download (hash "%build%") has failed: "%stext)
                        updHash err
                    Right file -> do
                        liftIO $ BSL.writeFile updPath file
                        logInfo "Update was downloaded"
                        sm <- ncUpdateSemaphore <$> getNodeContext
                        liftIO $ putMVar sm cst
                        logInfo "Update MVar filled, wallet is notified"

-- | Download a file by its hash.
--
-- Tries all servers in turn, fails if none of them work.
downloadHash :: [Text] -> Hash LByteString -> IO (Either Text LByteString)
downloadHash updateServers h = do
    manager <- newManager tlsManagerSettings

    let -- try all servers in turn until there's a Right
        go errs (serv:rest) = do
            let uri = T.unpack serv <//> showHash h
            downloadUri manager uri h >>= \case
                Left e -> go (e:errs) rest
                Right r -> return (Right r)

        -- if there were no servers, that's really weird
        go [] [] = panic "no update servers are known"

        -- if we've tried all servers already, fail
        go errs [] = return . Left $
            sformat ("all update servers failed: "%listJsonIndent 2)
                    (reverse errs)

    go [] updateServers

-- Download a file and check its hash.
downloadUri :: Manager
            -> String
            -> Hash LByteString
            -> IO (Either Text LByteString)
downloadUri manager uri h = do
    request <- setRequestManager manager <$> parseRequest uri
    resp <- httpLBS request
    let (st, stc) = (getResponseStatus resp, getResponseStatusCode resp)
        h' = hash (getResponseBody resp)
    return $ if | stc /= 200 -> Left ("error, " <> show st)
                | h /= h'    -> Left "hash mismatch"
                | otherwise  -> Right (getResponseBody resp)

{- TODO
=======

* check timeouts?
* how should we in general deal with e.g. 1B/s download speed?
* if we expect updates to be big, use laziness/conduits (httpLBS isn't lazy,
  despite the “L” in its name)

-}
