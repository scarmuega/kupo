--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}

module Kupo.App.Http
    ( runServer
    , TraceHttpServer (..)
    ) where

import Kupo.Prelude

import Kupo.Configuration
    ( StandardCrypto )
import Kupo.Control.MonadDatabase
    ( Database (..) )
import Kupo.Control.MonadLog
    ( HasSeverityAnnotation (..), MonadLog (..), Severity (..), Tracer )
import Kupo.Data.ChainSync
    ( pointToJson, unsafeMkPoint )
import Kupo.Data.Pattern
    ( patternFromText
    , patternToQueryLike
    , resultToJson
    , unsafeMkResult
    , wildcard
    )
import Network.HTTP.Types.Header
    ( Header, hContentLength, hContentType )
import Network.HTTP.Types.Status
    ( status200, status400, status404, status406 )
import Network.Wai
    ( Application
    , Middleware
    , Response
    , pathInfo
    , requestMethod
    , responseLBS
    , responseStatus
    , responseStream
    )

import qualified Data.Aeson as Json
import qualified Data.Binary.Builder as B
import qualified Data.ByteString.Lazy as BL
import qualified Network.HTTP.Types.Status as Http
import qualified Network.Wai.Handler.Warp as Warp

--
-- Server
--

runServer
    :: Tracer IO TraceHttpServer
    -> (forall a. (Database IO -> IO a) -> IO a)
    -> String
    -> Int
    -> IO ()
runServer tr withDatabase host port =
    Warp.runSettings settings $ tracerMiddleware tr (app withDatabase)
  where
    settings = Warp.defaultSettings
        & Warp.setPort port
        & Warp.setHost (fromString host)
        & Warp.setServerName "kupo"
        & Warp.setBeforeMainLoop (logWith tr TraceServerListening{host,port})

--
-- Router
--

app :: (forall a. (Database IO -> IO a) -> IO a) -> Application
app withDatabase req send = withDatabase $ \db ->
    case (requestMethod req, pathInfo req) of
        ("GET", [ "v1", "checkpoints" ]) ->
            send $ handleGetCheckpoints db

        ("GET", [ "v1", "matches" ]) ->
            send $ handleGetMatches db Nothing

        ("GET", [ "v1", "matches", arg0 ]) ->
            send $ handleGetMatches db (Just (arg0, Nothing))

        ("GET", [ "v1", "matches", arg0, arg1 ]) ->
            send $ handleGetMatches db (Just (arg0, Just arg1))

        ("GET", _) ->
            send handleNotFound

        (_, _) ->
            send handleMethodNotAllowed

--
-- Handlers
--

handleGetCheckpoints
    :: Database IO
    -> Response
handleGetCheckpoints Database{..} = do
    responseStreamJson (pointToJson @StandardCrypto) $ \yield done -> do
        points <- runTransaction (listCheckpointsDesc unsafeMkPoint)
        mapM_ yield points
        done

handleGetMatches
    :: Database IO
    -> Maybe (Text, Maybe Text)
    -> Response
handleGetMatches Database{..} query = do
    let txt = maybe wildcard (\(a0, a1) -> a0 <> maybe "" ("/" <>) a1) query
    case patternFromText @StandardCrypto txt of
        Nothing ->
            handleInvalidPattern
        Just p -> do
            responseStreamJson (resultToJson @StandardCrypto) $ \yield done -> do
                runTransaction $ foldInputsByAddress
                    (patternToQueryLike p)
                    (\a0 a1 a2 a3 -> yield . unsafeMkResult a0 a1 a2 a3)
                done

handleInvalidPattern :: Response
handleInvalidPattern = do
    responseJson status400 defaultHeaders $ HttpError
        { hint = "Invalid pattern! To fetch matches, you may provide any valid \
                 \pattern, including wildcards ('*') or full addresses. Make \
                 \sure to double-check the documentation at: \
                 \<https://cardanosolutions.github.io/kupo>!"
        }

handleNotFound :: Response
handleNotFound =
    responseJson status404 defaultHeaders $ HttpError
        { hint = "Endpoint not found. Make sure to double-check the \
                 \documentation at: <https://cardanosolutions.github.io/kupo>!"
        }

handleMethodNotAllowed :: Response
handleMethodNotAllowed =
    responseJson status406 defaultHeaders $ HttpError
        { hint = "Unsupported method called on known endpoint. Make sure to \
                 \double-check the documentation at: \
                 \<https://cardanosolutions.github.io/kupo>!"
        }

--
-- Helpers
--

data HttpError = HttpError
    { hint :: Text }
    deriving stock (Generic)
    deriving anyclass (ToJSON)

defaultHeaders :: [Header]
defaultHeaders =
    [ ( hContentType, "application/json; charset=utf-8" )
    ]

responseJson
    :: ToJSON a
    => Http.Status
    -> [Header]
    -> a
    -> Response
responseJson status headers a =
    let
        bytes = B.toLazyByteString $ Json.fromEncoding (Json.toEncoding a)
        len = BL.length bytes
        contentLength = ( hContentLength, encodeUtf8 (show @Text len) )
     in
        responseLBS status (contentLength : headers) bytes

responseStreamJson
    :: (a -> Json.Encoding)
    -> ((a -> IO ()) -> IO () -> IO ())
    -> Response
responseStreamJson encode callback = do
    responseStream status200 defaultHeaders $ \write flush -> do
        ref <- newIORef True
        write openBracket
        callback
            (\a -> do
                isFirstResult <- readIORef ref
                write (separator isFirstResult <> Json.fromEncoding (encode a))
                writeIORef ref False
            )
            (write closeBracket >> flush)
  where
    openBracket = B.putCharUtf8 '['
    closeBracket = B.putCharUtf8 ']'
    separator isFirstResult
        | isFirstResult = mempty
        | otherwise     = B.putCharUtf8 ','


--
-- Tracer
--

tracerMiddleware :: Tracer IO TraceHttpServer -> Middleware
tracerMiddleware tr runApp req send = do
    runApp req $ \res -> do
        let status = mkStatus (responseStatus res)
        logWith tr $ TraceRequest {method, path, status}
        send res
  where
    method = decodeUtf8 (requestMethod req)
    path = pathInfo req

data TraceHttpServer where
    TraceServerListening
        :: { host :: String, port :: Int }
        -> TraceHttpServer
    TraceRequest
        :: { method :: Text, path :: [Text], status :: Status }
        -> TraceHttpServer
    deriving stock (Generic)

instance HasSeverityAnnotation TraceHttpServer where
    getSeverityAnnotation = \case
        TraceServerListening{} -> Notice
        TraceRequest{} -> Info

instance ToJSON TraceHttpServer where
    toEncoding =
        defaultGenericToEncoding

--
-- Status
--

data Status = Status
    { statusCode :: Int
    , statusMessage :: Text
    } deriving stock (Generic)
      deriving anyclass (ToJSON)

mkStatus :: Http.Status -> Status
mkStatus status = Status
    { statusCode = Http.statusCode status
    , statusMessage = decodeUtf8 (Http.statusMessage status)
    }
