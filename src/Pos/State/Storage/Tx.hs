{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE TemplateHaskell       #-}

-- | Internal state of the transaction-handling worker.

module Pos.State.Storage.Tx
       (
         TxStorage
       , HasTxStorage(txStorage)

       , addTx
       ) where

import           Control.Lens  (makeClassy)
import           Data.Default  (Default, def)
import           Data.SafeCopy (base, deriveSafeCopySimple)
import           Universum

import           Pos.Genesis   (genesisUtxo)
import           Pos.Types     (Tx, Utxo)

data TxStorage = TxStorage
    { -- | Local set of transactions. These are valid (with respect to
      -- utxo) transactions which are known to the node and are not
      -- included in the blockchain store by the node.
      _txLocalTxns :: !(HashSet Tx)
    , -- | Set of unspent transaction outputs. It is need to check new
      -- transactions and run follow-the-satoshi, for example.
      _txUtxo      :: !Utxo
    }

makeClassy ''TxStorage
deriveSafeCopySimple 0 'base ''TxStorage

instance Default TxStorage where
    def =
        TxStorage
        { _txLocalTxns = mempty
        , _txUtxo = genesisUtxo
        }

type Update a = forall m x. (HasTxStorage x, MonadState x m) => m a
type Query a = forall m x. (HasTxStorage x, MonadReader x m) => m a

-- | Add transaction to storage if it is fully valid. Returns True iff
-- transaction has been added.
addTx :: Tx -> Update Bool
addTx _ = pure False