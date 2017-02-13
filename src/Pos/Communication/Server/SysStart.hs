{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

-- | Server which handles system start.

module Pos.Communication.Server.SysStart
       ( sysStartReqListener
       , sysStartRespListener
       , handleSysStartResp
       ) where

import           Control.Concurrent.MVar  (MVar, tryPutMVar)
import           Formatting               (build, sformat, shown, (%))
import           Node                     (ConversationActions (..), Listener,
                                           ListenerAction (..), NodeId,
                                           SendActions (sendTo))
import           System.Wlog              (logInfo)

import           Universum

import           Pos.Binary.Communication ()
import           Pos.Binary.DHTModel      ()
import           Pos.Communication.BiP    (BiP)
import           Pos.Communication.Types  (SysStartRequest (..), SysStartResponse (..))
import           Pos.DHT.Model            (sendToNeighbors')
import           Pos.Types                (Timestamp)
import           Pos.WorkMode             (MinWorkMode)

-- | Listener for 'SysStartRequest' message.
sysStartReqListener
    :: MinWorkMode m => Timestamp -> Listener BiP m
sysStartReqListener sysStart = ListenerActionConversation $
    \peerId conv  -> do
        (mReq :: Maybe SysStartRequest) <- recv conv
        whenJust mReq $ \_ -> do
            logInfo $ sformat
                ("Received sysStart request from "%shown%", sending "%build)
                peerId sysStart
            send conv $ SysStartResponse sysStart

-- | Listener for 'SysStartResponce' message.
sysStartRespListener
    :: MinWorkMode m
    => MVar Timestamp -> Listener BiP m
sysStartRespListener mvar = ListenerActionOneMsg $ handleSysStartResp mvar

handleSysStartResp
    :: MinWorkMode m
    => MVar Timestamp -> NodeId -> SendActions BiP m -> SysStartResponse -> m ()
handleSysStartResp mvar peerId sendActions (SysStartResponse sysStart) = do
        logInfo $ sformat
            ("Received sysStart response from "%shown%", "%build)
            peerId sysStart
        whenM (liftIO . tryPutMVar mvar $ sysStart) $
            sendToNeighbors' Nothing sendActions $ SysStartResponse sysStart
