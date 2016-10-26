{-# LANGUAGE TypeApplications #-}
module Bench.Pos.Criterion.FollowTheSatoshiBench
  ( runBenchmark
  ) where

import           Criterion.Main       (Benchmark, bench, defaultConfig, defaultMainWith,
                                       env, whnf)
import           Criterion.Types      (Config (..))
import           Data.Map             (fromList)
import           Data.Maybe
import           Formatting           (int, sformat, (%))
import           Test.QuickCheck      (Arbitrary (..), Gen, generate, infiniteList)
import           Universum

import           Pos.FollowTheSatoshi (followTheSatoshi)
import           Pos.Types            (Utxo)

type UtxoSize = Int

-- TODO: make a trick and use special unsafe arbitrary instances
-- for generation of such things
arbitraryUtxoOfSize :: UtxoSize -> Gen Utxo
arbitraryUtxoOfSize n = fromList . take n <$> infiniteList

ftsBench :: UtxoSize -> Benchmark
ftsBench n = env genArgs $ bench msg . whnf (uncurry followTheSatoshi)
  where genArgs = generate $ (,) <$> arbitrary <*> arbitraryUtxoOfSize n
        msg = toS $ sformat ("followTheSatoshi: Utxo of size "%int) n

ftsConfig :: Config
ftsConfig = defaultConfig
  { reportFile = Just "followTheSatoshi.html"
  }

runBenchmark :: IO ()
runBenchmark = defaultMainWith ftsConfig $ map ftsBench [1000, 10000, 100000]