-- | Functions for operating with transactions

module Pos.Wallet.Tx
       ( makePubKeyTx
       , makeMOfNTx
       , submitTx
       , submitTxRaw
       , createTx
       , createMOfNTx
       ) where

import           Control.Lens              ((^.), _1)
import           Control.Monad.Except      (ExceptT (..), runExceptT)
import           Formatting                (build, sformat, (%))
import           Mockable                  (mapConcurrently)
import           Node                      (SendActions)
import           Pos.Util.TimeWarp         (NetworkAddress)
import           System.Wlog               (logError, logInfo)
import           Universum                 hiding (mapConcurrently)

import           Pos.Binary                ()
import           Pos.Communication.BiP     (BiP)
import           Pos.Communication.Methods (sendTx)
import           Pos.Crypto                (SecretKey, hash, toPublic)
import           Pos.Types                 (SlotId, TxAux, TxOutAux, makePubKeyAddress,
                                            txaF)
import           Pos.WorkMode              (MinWorkMode)

import           Pos.Wallet.Tx.Pure        (TxError, createMOfNTx, createTx, makeMOfNTx,
                                            makePubKeyTx)
import           Pos.Wallet.WalletMode     (TxMode, getOwnUtxo, saveTx)

-- | Construct Tx using secret key and given list of desired outputs
submitTx
    :: TxMode ssc m
    => SendActions BiP m
    -> SecretKey
    -> [NetworkAddress]
    -> [TxOutAux]
    -> SlotId
    -> m (Either TxError TxAux)
submitTx _ _ [] _ _ = do
    logError "No addresses to send"
    return (Left "submitTx failed")
submitTx sendActions sk na outputs sid = do
    utxo <- getOwnUtxo $ makePubKeyAddress $ toPublic sk
    runExceptT $ do
        txw <- ExceptT $ return $ createTx utxo sk outputs
        let txId = hash (txw ^. _1)
        lift $ submitTxRaw sendActions na txw
        lift $ saveTx (txId, (sid, txw))
        return txw

-- | Send the ready-to-use transaction
submitTxRaw :: MinWorkMode m => SendActions BiP m -> [NetworkAddress] -> TxAux -> m ()
submitTxRaw sa na tx = do
    let txId = hash (tx ^. _1)
    logInfo $ sformat ("Submitting transaction: "%txaF) tx
    logInfo $ sformat ("Transaction id: "%build) txId
    void $ mapConcurrently (flip (sendTx sa) tx) na
