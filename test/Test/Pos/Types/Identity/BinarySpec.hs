-- | This module tests Binary instances.

module Test.Pos.Types.Identity.BinarySpec
       ( spec
       ) where

import           Test.Hspec    (Spec, describe)
import           Universum

import qualified Pos.Txp       as T
import qualified Pos.Types     as T

import           Test.Pos.Util (binaryTest)

spec :: Spec
spec = describe "Types" $ do
    describe "Bi instances" $ do
        binaryTest @T.EpochIndex
        binaryTest @T.LocalSlotIndex
        binaryTest @T.SlotId
        binaryTest @T.Coin
        binaryTest @T.Address
        binaryTest @T.TxInWitness
        binaryTest @T.TxDistribution
        binaryTest @T.TxIn
        binaryTest @T.TxOut
        binaryTest @T.Tx
        binaryTest @T.SharedSeed
        binaryTest @T.ChainDifficulty
