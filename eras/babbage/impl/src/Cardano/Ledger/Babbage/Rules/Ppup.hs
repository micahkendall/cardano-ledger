{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Babbage.Rules.Ppup () where

import Cardano.Ledger.Babbage.Era (BabbageEra)
import Cardano.Ledger.Core
import Cardano.Ledger.Shelley.Rules (ShelleyPpupPredFailure)

type instance EraRuleFailure "PPUP" (BabbageEra c) = ShelleyPpupPredFailure (BabbageEra c)

instance InjectRuleFailure "PPUP" ShelleyPpupPredFailure (BabbageEra c)
