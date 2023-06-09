{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NumericUnderscores #-}

module Cardano.Marketplace.Common.TransactionUtils where

import Cardano.Api.Shelley
import Cardano.Api
import Cardano.Kuber.Api
import Cardano.Kuber.Data.Parsers
  ( parseAssetId,

    parseAssetNQuantity,
    parseScriptData,
    parseValueText, scriptDataParser, parseSignKey
  )
import Cardano.Kuber.Util
    ( pkhToMaybeAddr, skeyToAddrInEra, queryUtxos, toPlutusAddress )
import qualified Data.Text as T
import qualified Data.ByteString.Char8 as BS8
import qualified Plutus.V1.Ledger.Address as Plutus
import qualified Plutus.V1.Ledger.Api as Plutus
import Plutus.Contracts.V2.SimpleMarketplace (SimpleSale (SimpleSale), simpleMarketplacePlutusV2)

import qualified Cardano.Api.Shelley as Shelley
import Plutus.V1.Ledger.Api (toData)
import Control.Exception (throwIO)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Map as Map
import Data.List (intercalate)
import Cardano.Kuber.Console.ConsoleWritable (showStr)
import qualified Data.Text.Lazy as TLE
import qualified Data.Aeson.Text as Aeson
import qualified Data.Text.IO as T
import System.Environment (getEnv)
import qualified Data.Aeson as A
import qualified Data.Aeson.Text as A
import Plutus.V2.Ledger.Api (dataToBuiltinData)
import Cardano.Api.Byron (Address(ByronAddress))



--Convert to Addr any from Addr in era
getAddrAnyFromEra addrEra = fromMaybe (error "unexpected error converting address to another type") (deserialiseAddress AsAddressAny (serialiseAddress addrEra))

--Get Addr any from given sign key
getAddrAnyFromSignKey ctx signKey =
  getAddrAnyFromEra $ skeyToAddrInEra signKey (getNetworkId ctx)

--Get Addr in era from  given sign key
getAddrEraFromSignKey ctx signKey =
  skeyToAddrInEra signKey (getNetworkId ctx)

marketAddressShelley :: NetworkId -> Address ShelleyAddr
marketAddressShelley network = makeShelleyAddress network scriptCredential NoStakeAddress

marketAddressInEra :: NetworkId -> AddressInEra BabbageEra
marketAddressInEra network = makeShelleyAddressInEra network scriptCredential NoStakeAddress

scriptCredential :: Cardano.Api.Shelley.PaymentCredential
scriptCredential = PaymentCredentialByScript marketHash
  where
    marketHash = hashScript marketScript
    marketScript = PlutusScript PlutusScriptV2 simpleMarketplacePlutusV2

queryMarketUtxos :: ChainInfo v => v -> Address ShelleyAddr -> IO (UTxO BabbageEra)
queryMarketUtxos ctx addr = do
  utxos <- queryUtxos (getConnectInfo ctx) $ Set.singleton  (toAddressAny addr)
  case utxos of
    Left err -> error $ "Error while querying utxos " ++ show err
    Right utxos' -> pure utxos'

constructDatum :: AddressInEra BabbageEra -> Integer -> ScriptData
constructDatum sellerAddr costOfAsset =
  -- Convert AddressInEra to Plutus.Address
  let plutusAddr =  toPlutusAddress sellerAddrShelley
      sellerAddrShelley = case sellerAddr of { AddressInEra atie ad -> case ad of
                                                 ByronAddress ad' -> error "Byron era address Not supported"
                                                 addr@(ShelleyAddress net cre sr )-> addr  }
      datum = SimpleSale plutusAddr costOfAsset

   in fromPlutusData $ toData datum

getTxIdFromTx :: Tx BabbageEra -> String
getTxIdFromTx tx = T.unpack $ serialiseToRawBytesHexText $ getTxId $ getTxBody tx

unMaybe :: String -> Maybe a -> a
unMaybe errStr m = case m of
  Nothing -> error errStr
  Just x -> x

plutusAddressToAddressInEra :: NetworkId -> Plutus.Address -> AddressInEra BabbageEra
plutusAddressToAddressInEra nw addr = unMaybe "Error Cannot convert pluuts address to address in era" $ pkhToMaybeAddr nw $ unMaybe "Error Validator hash is not supported." $ Plutus.toPubKeyHash addr

printTxBuilder :: TxBuilder -> IO ()
printTxBuilder txBuilder = do
  putStrLn $ BS8.unpack $ prettyPrintJSON txBuilder

parseSimpleSale :: String -> IO (ScriptData, SimpleSale)
parseSimpleSale datumStr = do
  scriptData <- parseScriptData $ T.pack datumStr
  let simpleSale = unMaybe "Failed to convert datum to SimpleSale" $ Plutus.fromBuiltinData $ dataToBuiltinData $ toPlutusData scriptData
  return (scriptData, simpleSale)

submitTransaction :: ChainInfo v => v -> TxBuilder -> IO ()
submitTransaction dcInfo txOperations  = do
  txE <- txBuilderToTxIO dcInfo txOperations
  tx <- case txE of
    Left fe -> throwIO fe
    Right txBody -> pure txBody
  result <- submitTx (getConnectInfo dcInfo) tx
  case result of
    Left err -> throwIO err
    Right _ -> pure ()
  putStrLn $ "Transaction submitted sucessfully with transaction hash " ++ getTxIdFromTx tx


encodeScriptData :: ScriptData -> String
encodeScriptData sd =  TLE.unpack . Aeson.encodeToLazyText $  scriptDataToJsonDetailedSchema sd

jsonEncodeUtxos (UTxO utxoMap) =  intercalate " \n" (map toStrings $ Map.toList utxoMap)
  where
    toStrings (TxIn txId (TxIx index),TxOut addr value datum refScript  )=
      let txInStr = showStr txId ++ "#" ++ show index
          utxoObject = A.object $  [ "txIn" A..= txInStr,
                                  "value" A..= renderTxOutValue value]
                                   ++ renderDatum datum  
                                   ++ renderRefScript refScript
      in   BS8.unpack $ prettyPrintJSON utxoObject
      -- showStr txId ++ 
      -- "#" ++  show index ++"\t:\t" ++ 
      -- (case value of
      -- TxOutAdaOnly oasie (Lovelace v) -> show v
      -- TxOutValue masie va ->  intercalate " +" (map vToString $valueToList va ) ) ++ " " ++
      -- (case datum of
      -- TxOutDatumNone -> "TxOutDatumNone"
      -- TxOutDatumHash s h -> show h
      -- TxOutDatumInline _ sd -> encodeScriptData sd
      -- _ -> ""
      -- ) 

    renderTxOutValue txOutValue = case txOutValue of
      TxOutAdaOnly oasie (Lovelace v) -> show v
      TxOutValue masie va ->  intercalate " +" (map vToString $ valueToList va )
    renderDatum datum = case datum  of
            TxOutDatumNone -> []
            TxOutDatumHash sdsie ha -> [ "datumHash" A..= show ha]
            TxOutDatumInline rtisidsie sd -> [ "inlineDatum" A..= encodeScriptData sd  ]
            _  -> [ ]

    renderRefScript refScript = case refScript of
      ReferenceScriptNone -> []
      ReferenceScript _ sc ->  [ "refrenceScript" A..= ("present" ::String ) ]
        -- TLE.unpack $ A.encodeToLazyText refScript

    vToString (AssetId policy asset,Quantity v)=show v ++ " " ++ showStr  policy ++ "." ++ showStr  asset
    vToString (AdaAssetId, Quantity v) = if v >99999
      then(
        let _rem= v `rem` 1_000_000
            _quot= v `quot` 1_000_000
        in
        case _rem of
              0 -> show _quot ++ " Ada"
              v-> show _quot ++"." ++ show _rem++ " Ada"
      )
      else show v ++ " Lovelace"

getSignKey :: [Char] -> IO (SigningKey PaymentKey)
getSignKey skeyfile =
  getPath >>=  T.readFile  >>= parseSignKey
  where
  getPath = if not (null skeyfile) && head skeyfile == '~'
                          then (do
                            home <- getEnv "HOME"
                            pure  $ home ++  drop 1 skeyfile
                            )
                          else pure skeyfile
