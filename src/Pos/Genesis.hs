{-# LANGUAGE CPP #-}

{-| Blockchain genesis. Not to be confused with genesis block in epoch.
    Blockchain genesis means genesis values which are hardcoded in advance
    (before system starts doing anything). Genesis block in epoch exists
    in every epoch and it's not known in advance.
-}

module Pos.Genesis
       (
       -- * Static state
         StakeDistribution (..)
       , GenesisData (..)
       , compileGenData
#ifdef DEV_MODE
       , genesisAddresses
       , genesisKeyPairs
       , genesisPublicKeys
       , genesisSecretKeys
#endif
       , genesisStakeDistribution
       , genesisUtxo
       , genesisDelegation

       -- * Ssc
       -- , genesisLeaders

       -- * Update System
       , genesisProtocolVersion
       , genesisSoftwareVersions
       , genesisScriptVersion
       ) where

import           Control.Lens             ((%~), _head)
import           Data.Default             (Default (..))
import           Data.List                (genericLength, genericReplicate)
import qualified Data.Map.Strict          as M
import qualified Data.Text                as T
import           Formatting               (int, sformat, (%))
import           Serokell.Util            (enumerate)
import           Universum

import           Pos.Constants            (curSoftwareVersion, genesisN, mpcThreshold)
import           Pos.Crypto               (PublicKey, SecretKey, deterministicKeyGen,
                                           unsafeHash)
import           Pos.Genesis.Parser       (compileGenData)
import           Pos.Genesis.Types        (GenesisData (..), StakeDistribution (..))
import           Pos.Lrc.FollowTheSatoshi (followTheSatoshi)
import           Pos.Script.Type          (ScriptVersion)
import           Pos.Types                (Address (..), Coin, ProtocolVersion (..),
                                           SharedSeed (SharedSeed), SlotLeaders,
                                           StakeholderId, TxOut (..), Utxo,
                                           applyCoinPortion, coinToInteger, divCoin,
                                           makePubKeyAddress, mkCoin, unsafeAddCoin,
                                           unsafeMulCoin)
import           Pos.Types.Version        (SoftwareVersion (..))

----------------------------------------------------------------------------
-- Static state
----------------------------------------------------------------------------

#ifdef DEV_MODE
-- | List of pairs from 'SecretKey' with corresponding 'PublicKey'.
genesisKeyPairs :: [(PublicKey, SecretKey)]
genesisKeyPairs = map gen [0 .. genesisN - 1]
  where
    gen :: Int -> (PublicKey, SecretKey)
    gen =
        fromMaybe (panic "deterministicKeyGen failed in Genesis") .
        deterministicKeyGen .
        encodeUtf8 .
        T.take 32 . sformat ("My awesome 32-byte seed #" %int % "             ")

-- | List of 'SecrekKey'`s in genesis.
genesisSecretKeys :: [SecretKey]
genesisSecretKeys = map snd genesisKeyPairs

-- | List of 'PublicKey'`s in genesis.
genesisPublicKeys :: [PublicKey]
genesisPublicKeys = map fst genesisKeyPairs

-- | List of 'Address'`es in genesis. See 'genesisPublicKeys'.
genesisAddresses :: [Address]
genesisAddresses = map makePubKeyAddress genesisPublicKeys

genesisStakeDistribution :: StakeDistribution
genesisStakeDistribution = def
#else
genesisAddresses :: [Address]
genesisAddresses = gdAddresses compileGenData

genesisStakeDistribution :: StakeDistribution
genesisStakeDistribution = gdDistribution compileGenData
#endif

instance Default StakeDistribution where
    def = FlatStakes genesisN
              (mkCoin 10000 `unsafeMulCoin` (genesisN :: Int))

-- 10000 coins in total. For thresholds testing.
-- 0.5,0.25,0.125,0.0625,0.0312,0.0156,0.0078,0.0039,0.0019,0.0008,0.0006,0.0004,0.0002,0.0001
expTwoDistribution :: [Coin]
expTwoDistribution =
    map mkCoin [5000,2500,1250,625,312,156,78,39,19,8,6,4,2,1]

bitcoinDistribution20 :: [Coin]
bitcoinDistribution20 = map mkCoin
    [200,163,120,105,78,76,57,50,46,31,26,13,11,11,7,4,2,0,0,0]

stakeDistribution :: StakeDistribution -> [Coin]
stakeDistribution (FlatStakes stakeholders coins) =
    genericReplicate stakeholders val
  where
    val = coins `divCoin` stakeholders
stakeDistribution (BitcoinStakes stakeholders coins) =
    map normalize $ bitcoinDistribution1000Coins stakeholders
  where
    normalize x = x `unsafeMulCoin`
                  coinToInteger (coins `divCoin` (1000 :: Int))
stakeDistribution ExponentialStakes = expTwoDistribution
stakeDistribution TestnetStakes {..} =
    map (mkCoin . fromIntegral) $ basicDist & _head %~ (+ rmd)
  where
    -- Total number of richmen
    richs = fromIntegral sdRichmen
    -- Total number of poor
    poors = fromIntegral sdPoor
    -- Minimum amount of money to become rich
    thresholdRich = coinToInteger $ applyCoinPortion mpcThreshold sdTotalStake
    -- Maximal amount of total money which poor stakeholders can hold
    maxPoorStake = (thresholdRich - 1) * poors
    -- Minimum amount of richmen's money to prevent poors becoming richmen
    minRichStake = coinToInteger sdTotalStake - maxPoorStake
    -- Minimum amount of money per richman to maintain number of richmen
    minRich = minRichStake `div` richs
    -- Final amount of money per richman
    rich = max thresholdRich minRich
    -- Amount of money left to poor
    poorStake = coinToInteger sdTotalStake - richs * rich
    -- Money per poor and modulo (it goes to first richman)
    (poor, rmd) = if poors == 0
                  then (0, poorStake)
                  else (poorStake `div` poors, poorStake `mod` poors)
    -- Coin distribution (w/o modulo added)
    basicDist = genericReplicate richs rich ++ genericReplicate poors poor

bitcoinDistribution1000Coins :: Word -> [Coin]
bitcoinDistribution1000Coins stakeholders
    | stakeholders < 20 = stakeDistribution
          (FlatStakes stakeholders (mkCoin 1000))
    | stakeholders == 20 = bitcoinDistribution20
    | otherwise =
        foldl' (bitcoinDistributionImpl ratio) [] $
        enumerate bitcoinDistribution20
  where
    ratio = fromIntegral stakeholders / 20

bitcoinDistributionImpl :: Double -> [Coin] -> (Int, Coin) -> [Coin]
bitcoinDistributionImpl ratio coins (coinIdx, coin) =
    coins ++ toAddValMax : replicate (toAddNum - 1) toAddValMin
  where
    toAddNumMax = ceiling ratio
    toAddNumMin = floor ratio
    toAddNum :: Int
    toAddNum =
        if genericLength coins + realToFrac toAddNumMax >
           realToFrac (coinIdx + 1) * ratio
            then toAddNumMin
            else toAddNumMax
    toAddValMin = coin `divCoin` toAddNum
    toAddValMax = coin `unsafeAddCoin`
                  (toAddValMin `unsafeMulCoin` (toAddNum - 1))

-- | Genesis 'Utxo'.
genesisUtxo :: StakeDistribution -> Utxo
genesisUtxo sd =
    M.fromList . zipWith zipF (stakeDistribution sd) $ genesisAddresses
  where
    zipF coin addr = ((unsafeHash addr, 0), (TxOut addr coin, []))

genesisDelegation :: HashMap StakeholderId [StakeholderId]
genesisDelegation = mempty

----------------------------------------------------------------------------
-- Slot leaders
----------------------------------------------------------------------------

genesisSeed :: SharedSeed
genesisSeed = SharedSeed "vasa opasa skovoroda Ggurda boroda provoda"

{-
-- | Leaders of genesis. See 'followTheSatoshi'.
genesisLeaders :: Utxo -> SlotLeaders
genesisLeaders = followTheSatoshi genesisSeed
-}

----------------------------------------------------------------------------
-- Update system
----------------------------------------------------------------------------

-- | ProtocolVersion used at the very beginning.
genesisProtocolVersion :: ProtocolVersion
genesisProtocolVersion =
    ProtocolVersion
    { pvMajor = 0
    , pvMinor = 0
    , pvAlt = 0
    }

-- | Software Versions
genesisSoftwareVersions :: [SoftwareVersion]
genesisSoftwareVersions = [curSoftwareVersion { svNumber = 0 }]

-- | ScriptVersion used at very beginning
genesisScriptVersion :: ScriptVersion
genesisScriptVersion = 0
