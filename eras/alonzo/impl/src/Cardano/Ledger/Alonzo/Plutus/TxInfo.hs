{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Alonzo.Plutus.TxInfo (
  ContextError (..),
  TxOutSource (..),
  transLookupTxOut,
  transTxOut,
  transValidityInterval,
  transPolicyID,
  transAssetName,
  transMultiAsset,
  transMintValue,
  transValue,
  transWithdrawals,
  transDataPair,
  transTxCert,
  transScriptPurpose,
  transTxBodyId,
  transTxBodyCerts,
  transTxBodyWithdrawals,
  transTxBodyReqSignerHashes,
  transTxWitsDatums,
)
where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (RewardAcnt (..), Withdrawals (..))
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Era (AlonzoEra)
import Cardano.Ledger.Alonzo.Plutus.Context
import Cardano.Ledger.Alonzo.Scripts (PlutusScript (..))
import Cardano.Ledger.Alonzo.Tx (ScriptPurpose (..))
import Cardano.Ledger.Alonzo.TxBody (
  AlonzoEraTxBody (..),
  AlonzoEraTxOut (..),
  mintTxBodyL,
  vldtTxBodyL,
 )
import Cardano.Ledger.Alonzo.TxWits (AlonzoEraTxWits (..), unTxDats)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), strictMaybeToMaybe)
import Cardano.Ledger.Binary (DecCBOR (..), EncCBOR (..))
import Cardano.Ledger.Binary.Coders (
  Decode (..),
  Encode (..),
  decode,
  encode,
  (!>),
  (<!),
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core
import Cardano.Ledger.Crypto (Crypto)
import Cardano.Ledger.Mary.Value (
  AssetName (..),
  MaryValue (..),
  MultiAsset (..),
  PolicyID (..),
 )
import Cardano.Ledger.Plutus.Language (Language (..))
import Cardano.Ledger.Plutus.TxInfo
import Cardano.Ledger.PoolParams (PoolParams (..))
import Cardano.Ledger.Rules.ValidationMode (Inject (..))
import Cardano.Ledger.SafeHash (hashAnnotated)
import qualified Cardano.Ledger.Shelley.HardForks as HardForks
import Cardano.Ledger.Shelley.TxCert
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.UTxO (UTxO (..))
import Cardano.Ledger.Val (zero)
import Cardano.Slotting.EpochInfo (EpochInfo)
import Cardano.Slotting.Slot (EpochNo (..))
import Cardano.Slotting.Time (SystemStart)
import Control.Arrow (left)
import Control.DeepSeq (NFData)
import Control.Monad (forM, guard)
import Data.ByteString.Short as SBS (fromShort)
import Data.Foldable as F (Foldable (..))
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, isNothing, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import GHC.Generics (Generic)
import Lens.Micro ((^.))
import NoThunks.Class (NoThunks)
import qualified PlutusLedgerApi.V1 as PV1

instance Crypto c => EraPlutusTxInfo 'PlutusV1 (AlonzoEra c) where
  toPlutusTxCert _ = pure . transTxCert

  toPlutusScriptPurpose = transScriptPurpose

  toPlutusTxInfo proxy pp epochInfo systemStart utxo tx = do
    timeRange <- transValidityInterval pp epochInfo systemStart (txBody ^. vldtTxBodyL)
    txInsMaybes <- forM (Set.toList (txBody ^. inputsTxBodyL)) $ \txIn -> do
      txOut <- transLookupTxOut utxo txIn
      pure $ PV1.TxInInfo (transTxIn txIn) <$> transTxOut txOut
    txCerts <- transTxBodyCerts proxy txBody
    Right $
      PV1.TxInfo
        { -- A mistake was made in Alonzo of filtering out Byron addresses, so we need to
          -- preserve this behavior by only retaining the Just case:
          PV1.txInfoInputs = catMaybes txInsMaybes
        , PV1.txInfoOutputs = mapMaybe transTxOut $ F.toList (txBody ^. outputsTxBodyL)
        , PV1.txInfoFee = transCoin (txBody ^. feeTxBodyL)
        , PV1.txInfoMint = transMintValue (txBody ^. mintTxBodyL)
        , PV1.txInfoDCert = txCerts
        , PV1.txInfoWdrl = transTxBodyWithdrawals txBody
        , PV1.txInfoValidRange = timeRange
        , PV1.txInfoSignatories = transTxBodyReqSignerHashes txBody
        , PV1.txInfoData = transTxWitsDatums (tx ^. witsTxL)
        , PV1.txInfoId = transTxBodyId txBody
        }
    where
      txBody = tx ^. bodyTxL

  toPlutusScriptContext proxy txInfo scriptPurpose =
    PV1.ScriptContext txInfo <$> toPlutusScriptPurpose proxy scriptPurpose

instance Crypto c => EraPlutusContext (AlonzoEra c) where
  data ContextError (AlonzoEra c)
    = TranslationLogicMissingInput !(TxIn c)
    | TimeTranslationPastHorizon !Text
    deriving (Eq, Show, Generic)

  mkPlutusScriptContext (AlonzoPlutusV1 p) =
    mkPlutusLanguageContext p

instance NoThunks (ContextError (AlonzoEra c))

instance Inject (ContextError (AlonzoEra c)) (ContextError (AlonzoEra c))

instance Crypto c => NFData (ContextError (AlonzoEra c))

instance Crypto c => EncCBOR (ContextError (AlonzoEra c)) where
  encCBOR = \case
    TranslationLogicMissingInput txIn ->
      encode $ Sum TranslationLogicMissingInput 1 !> To txIn
    TimeTranslationPastHorizon err ->
      encode $ Sum TimeTranslationPastHorizon 7 !> To err

instance Crypto c => DecCBOR (ContextError (AlonzoEra c)) where
  decCBOR = decode $ Summands "ContextError" $ \case
    1 -> SumD TranslationLogicMissingInput <! From
    7 -> SumD TimeTranslationPastHorizon <! From
    n -> Invalid n

transLookupTxOut ::
  Inject (ContextError (AlonzoEra (EraCrypto era))) a =>
  UTxO era ->
  TxIn (EraCrypto era) ->
  Either a (TxOut era)
transLookupTxOut (UTxO utxo) txIn =
  case Map.lookup txIn utxo of
    Nothing -> Left $ inject $ TranslationLogicMissingInput txIn
    Just txOut -> Right txOut

-- | Translate a validity interval to POSIX time
transValidityInterval ::
  forall era a.
  (Inject (ContextError (AlonzoEra (EraCrypto era))) a, EraPParams era) =>
  PParams era ->
  EpochInfo (Either Text) ->
  SystemStart ->
  ValidityInterval ->
  Either a PV1.POSIXTimeRange
transValidityInterval pp epochInfo systemStart = \case
  ValidityInterval SNothing SNothing -> pure PV1.always
  ValidityInterval (SJust i) SNothing -> PV1.from <$> transSlotToPOSIXTime i
  ValidityInterval SNothing (SJust i) -> do
    t <- transSlotToPOSIXTime i
    pure $
      if HardForks.translateUpperBoundForPlutusScripts (pp ^. ppProtocolVersionL)
        then
          PV1.Interval
            (PV1.LowerBound PV1.NegInf True)
            (PV1.strictUpperBound t)
        else PV1.to t
  ValidityInterval (SJust i) (SJust j) -> do
    t1 <- transSlotToPOSIXTime i
    t2 <- transSlotToPOSIXTime j
    pure $
      PV1.Interval
        (PV1.lowerBound t1)
        (PV1.strictUpperBound t2)
  where
    transSlotToPOSIXTime =
      left (inject . TimeTranslationPastHorizon @(EraCrypto era))
        . slotToPOSIXTime epochInfo systemStart

-- | Translate a TxOut. Returns `Nothing` if a Byron address is present in the TxOut.
transTxOut ::
  (Value era ~ MaryValue c, AlonzoEraTxOut era) => TxOut era -> Maybe PV1.TxOut
transTxOut txOut = do
  -- Minor optimization:
  -- We can check for Byron address without decompacting the address in the TxOut
  guard $ isNothing (txOut ^. bootAddrTxOutF)
  let val = txOut ^. valueTxOutL
      dataHash = txOut ^. dataHashTxOutL
  address <- transAddr (txOut ^. addrTxOutL)
  pure $ PV1.TxOut address (transValue val) (transDataHash <$> strictMaybeToMaybe dataHash)

-- | Translate all `Withdrawal`s from within a `TxBody`
transTxBodyId :: EraTxBody era => TxBody era -> PV1.TxId
transTxBodyId txBody = PV1.TxId (transSafeHash (hashAnnotated txBody))

-- | Translate all `TxCert`s from within a `TxBody`
transTxBodyCerts ::
  (EraPlutusTxInfo l era, EraTxBody era) =>
  proxy l ->
  TxBody era ->
  Either (ContextError era) [PlutusTxCert l]
transTxBodyCerts proxy txBody =
  mapM (toPlutusTxCert proxy) $ F.toList (txBody ^. certsTxBodyL)

transWithdrawals :: Withdrawals c -> Map.Map PV1.StakingCredential Integer
transWithdrawals (Withdrawals mp) = Map.foldlWithKey' accum Map.empty mp
  where
    accum ans (RewardAcnt _networkId cred) (Coin n) =
      Map.insert (PV1.StakingHash (transCred cred)) n ans

-- | Translate all `Withdrawal`s from within a `TxBody`
transTxBodyWithdrawals :: EraTxBody era => TxBody era -> [(PV1.StakingCredential, Integer)]
transTxBodyWithdrawals txBody = Map.toList (transWithdrawals (txBody ^. withdrawalsTxBodyL))

-- | Translate all required signers produced by `reqSignerHashesTxBodyL`s from within a
-- `TxBody`
transTxBodyReqSignerHashes :: AlonzoEraTxBody era => TxBody era -> [PV1.PubKeyHash]
transTxBodyReqSignerHashes txBody = transKeyHash <$> Set.toList (txBody ^. reqSignerHashesTxBodyL)

-- | Translate all `TxDats`s from within `TxWits`
transTxWitsDatums :: AlonzoEraTxWits era => TxWits era -> [(PV1.DatumHash, PV1.Datum)]
transTxWitsDatums txWits = transDataPair <$> Map.toList (unTxDats $ txWits ^. datsTxWitsL)

-- ==================================
-- translate Values

transPolicyID :: PolicyID c -> PV1.CurrencySymbol
transPolicyID (PolicyID (ScriptHash x)) = PV1.CurrencySymbol (PV1.toBuiltin (hashToBytes x))

transAssetName :: AssetName -> PV1.TokenName
transAssetName (AssetName bs) = PV1.TokenName (PV1.toBuiltin (SBS.fromShort bs))

transMultiAsset :: MultiAsset c -> PV1.Value
transMultiAsset ma = transMultiAssetInternal ma mempty

transMultiAssetInternal :: MultiAsset c -> PV1.Value -> PV1.Value
transMultiAssetInternal (MultiAsset m) initAcc = Map.foldlWithKey' accum1 initAcc m
  where
    accum1 ans sym mp2 = Map.foldlWithKey' accum2 ans mp2
      where
        accum2 ans2 tok quantity =
          PV1.unionWith
            (+)
            ans2
            (PV1.singleton (transPolicyID sym) (transAssetName tok) quantity)

-- | Hysterical raisins:
--
-- Previously transaction body contained a mint field with MaryValue instead of a
-- MultiAsset, which has changed since then to just MultiAsset (because minting ADA
-- makes no sense). However, if we don't preserve previous translation, scripts that
-- previously succeeded will fail.
transMintValue :: MultiAsset c -> PV1.Value
transMintValue m = transMultiAssetInternal m (transCoin zero)

transValue :: MaryValue c -> PV1.Value
transValue (MaryValue c m) = transCoin c <> transMultiAsset m

-- =============================================
-- translate fields like TxCert, Withdrawals, and similar

transTxCert :: (ShelleyEraTxCert era, ProtVerAtMost era 8) => TxCert era -> PV1.DCert
transTxCert = \case
  RegTxCert stakeCred ->
    PV1.DCertDelegRegKey (PV1.StakingHash (transCred stakeCred))
  UnRegTxCert stakeCred ->
    PV1.DCertDelegDeRegKey (PV1.StakingHash (transCred stakeCred))
  DelegStakeTxCert stakeCred keyHash ->
    PV1.DCertDelegDelegate (PV1.StakingHash (transCred stakeCred)) (transKeyHash keyHash)
  RegPoolTxCert (PoolParams {ppId, ppVrf}) ->
    PV1.DCertPoolRegister (transKeyHash ppId) (PV1.PubKeyHash (PV1.toBuiltin (hashToBytes ppVrf)))
  RetirePoolTxCert poolId (EpochNo i) ->
    PV1.DCertPoolRetire (transKeyHash poolId) (toInteger i)
  GenesisDelegTxCert {} -> PV1.DCertGenesis
  MirTxCert {} -> PV1.DCertMir

transScriptPurpose ::
  (EraPlutusTxInfo l era, PlutusTxCert l ~ PV1.DCert) =>
  proxy l ->
  ScriptPurpose era ->
  Either (ContextError era) PV1.ScriptPurpose
transScriptPurpose proxy = \case
  Minting policyId -> pure $ PV1.Minting (transPolicyID policyId)
  Spending txIn -> pure $ PV1.Spending (transTxIn txIn)
  Rewarding (RewardAcnt _networkId cred) ->
    pure $ PV1.Rewarding (PV1.StakingHash (transCred cred))
  Certifying txCert -> PV1.Certifying <$> toPlutusTxCert proxy txCert