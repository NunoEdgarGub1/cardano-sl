-- | This module tests Binary instances for Pos.Update types

module Test.Pos.Update.Identity.BinarySpec
       ( spec
       ) where

import           Test.Hspec               (Spec, describe)
import           Universum

import           Pos.Binary               ()
-- import qualified Pos.Communication        as C
import           Pos.Communication.Relay  ()
import qualified Pos.Communication.Relay  as R
import qualified Pos.Update               as U
import           Test.Pos.Arbitrary.Infra ()

import           Test.Pos.Util            (binaryTest, msgLenLimitedTest,
                                           networkBinaryTest)

spec :: Spec
spec =
  describe "Update system" $ do
    describe "Bi instances" $ do
      describe "Core" $ do
        binaryTest @U.UpId
        binaryTest @U.BlockVersionData
        binaryTest @U.UpdateProposal
        binaryTest @U.UpdateVote
        binaryTest @U.UpdateData
        binaryTest @U.UpdatePayload
        binaryTest @U.SystemTag
      describe "Poll" $ do
        binaryTest @U.UndecidedProposalState
        binaryTest @U.UpsExtra
        binaryTest @U.DecidedProposalState
        binaryTest @U.DpsExtra
        binaryTest @U.ConfirmedProposalState
        -- TODO: binaryTest @U.ProposalState
      describe "Network" $ do
        networkBinaryTest @(R.InvMsg U.VoteId U.VoteMsgTag)
        networkBinaryTest @(R.ReqMsg U.VoteId U.VoteMsgTag)
        networkBinaryTest @(R.DataMsg U.UpdateVote)
        networkBinaryTest @(R.InvMsg U.UpId U.ProposalMsgTag)
        networkBinaryTest @(R.ReqMsg U.UpId U.ProposalMsgTag)
        networkBinaryTest @(R.DataMsg (U.UpdateProposal, [U.UpdateVote]))
    describe "Message length limit" $ do
        msgLenLimitedTest @(R.InvMsg U.VoteId U.VoteMsgTag)
        msgLenLimitedTest @(R.ReqMsg U.VoteId U.VoteMsgTag)
        msgLenLimitedTest @(R.InvMsg U.UpId U.ProposalMsgTag)
        msgLenLimitedTest @(R.ReqMsg U.UpId U.ProposalMsgTag)
        -- TODO [CSL-859]
        -- msgLenLimitedTest @(C.MaxSize (R.DataMsg (U.UpdateProposal, [U.UpdateVote])))
        msgLenLimitedTest @(R.DataMsg U.UpdateVote)
        -- msgLenLimitedTest @U.UpdateProposal
