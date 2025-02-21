{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE EmptyDataDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Shelley.Spec.Ledger.STS.Rupd
  ( RUPD,
    RupdEnv (..),
    PredicateFailure,
    RupdPredicateFailure,
    epochInfoRange,
    PulsingRewUpdate (..),
    startStep,
    pulseStep,
    completeStep,
    lift,
    Identity (..),
    createRUpd,
  )
where

import Cardano.Ledger.BaseTypes
  ( ShelleyBase,
    StrictMaybe (..),
    UnitInterval,
    activeSlotCoeff,
    epochInfo,
    maxLovelaceSupply,
    randomnessStabilisationWindow,
    securityParameter,
  )
import Cardano.Ledger.Coin (Coin (..))
import qualified Cardano.Ledger.Core as Core
import Cardano.Ledger.Era (Crypto, Era)
import Cardano.Slotting.EpochInfo.API (epochInfoRange)
import Control.Monad.Identity (Identity (..))
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Reader (asks)
import Control.Provenance (runProvM)
import Control.State.Transition
  ( STS (..),
    TRC (..),
    TransitionRule,
    judgmentContext,
    liftSTS,
  )
import Data.Functor ((<&>))
import GHC.Generics (Generic)
import GHC.Records
import NoThunks.Class (NoThunks (..))
import Numeric.Natural (Natural)
import Shelley.Spec.Ledger.EpochBoundary (BlocksMade)
import Shelley.Spec.Ledger.LedgerState
  ( EpochState,
    PulsingRewUpdate (..),
    completeStep,
    createRUpd,
    pulseStep,
    startStep,
  )
import Shelley.Spec.Ledger.PParams (ProtVer)
import Shelley.Spec.Ledger.Slot
  ( Duration (..),
    SlotNo,
    epochInfoEpoch,
    epochInfoFirst,
    epochInfoSize,
    (+*),
  )

data RUPD era

data RupdEnv era
  = RupdEnv (BlocksMade (Crypto era)) (EpochState era)

data RupdPredicateFailure era -- No predicate failures
  deriving (Show, Eq, Generic)

instance NoThunks (RupdPredicateFailure era)

instance
  ( Era era,
    HasField "_a0" (Core.PParams era) Rational,
    HasField "_d" (Core.PParams era) UnitInterval,
    HasField "_nOpt" (Core.PParams era) Natural,
    HasField "_protocolVersion" (Core.PParams era) ProtVer,
    HasField "_rho" (Core.PParams era) UnitInterval,
    HasField "_tau" (Core.PParams era) UnitInterval
  ) =>
  STS (RUPD era)
  where
  type State (RUPD era) = StrictMaybe (PulsingRewUpdate (Crypto era))
  type Signal (RUPD era) = SlotNo
  type Environment (RUPD era) = RupdEnv era
  type BaseM (RUPD era) = ShelleyBase
  type PredicateFailure (RUPD era) = RupdPredicateFailure era

  initialRules = [pure SNothing]
  transitionRules = [rupdTransition]

rupdTransition ::
  ( Era era,
    HasField "_a0" (Core.PParams era) Rational,
    HasField "_d" (Core.PParams era) UnitInterval,
    HasField "_nOpt" (Core.PParams era) Natural,
    HasField "_protocolVersion" (Core.PParams era) ProtVer,
    HasField "_rho" (Core.PParams era) UnitInterval,
    HasField "_tau" (Core.PParams era) UnitInterval
  ) =>
  TransitionRule (RUPD era)
rupdTransition = do
  TRC (RupdEnv b es, ru, s) <- judgmentContext
  (slotsPerEpoch, slot, maxLL, asc, k) <- liftSTS $ do
    ei <- asks epochInfo
    sr <- asks randomnessStabilisationWindow
    e <- epochInfoEpoch ei s
    slotsPerEpoch <- epochInfoSize ei e
    slot <- epochInfoFirst ei e <&> (+* (Duration sr))
    maxLL <- asks maxLovelaceSupply
    asc <- asks activeSlotCoeff
    k <- asks securityParameter -- Maximum number of blocks we are allowed to roll back
    return (slotsPerEpoch, slot, maxLL, asc, k)
  let maxsupply = Coin (fromIntegral maxLL)
  case (s <= slot) of
    -- Waiting for the stabiliy point, do nothing, keep waiting
    (True) -> pure SNothing
    -- More blocks to come, get things started or take a step
    (False) ->
      case ru of
        SNothing -> liftSTS $ runProvM $ pure $ SJust $ startStep slotsPerEpoch b es maxsupply asc k
        (SJust (p@(Pulsing _ _))) -> liftSTS $ runProvM $ (SJust <$> pulseStep p)
        (SJust (p@(Complete _))) -> pure (SJust p)
