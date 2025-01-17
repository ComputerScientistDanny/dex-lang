-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

module Live.Web (runWeb) where

import Control.Concurrent (readChan)
import Control.Monad (forever)

import Network.Wai (Application, StreamingBody, pathInfo,
                    responseStream, responseLBS, responseFile)
import Network.Wai.Handler.Warp (run)
import Network.HTTP.Types (status200, status404)
import Data.Aeson (ToJSON, encode)
import Data.Binary.Builder (fromByteString)
import Data.ByteString.Lazy (toStrict)
import qualified Data.ByteString as BS

-- import Paths_dex (getDataFileName)

import Live.Eval
import RenderHtml
import IncState
import Actor
import TopLevel
import Types.Source

runWeb :: FilePath -> EvalConfig -> TopStateEx -> IO ()
runWeb fname opts env = do
  resultsChan <- watchAndEvalFile fname opts env >>= renderResults
  putStrLn "Streaming output to http://localhost:8000/"
  run 8000 $ serveResults resultsChan

serveResults :: RenderedResultsServer -> Application
serveResults resultsSubscribe request respond = do
  print (pathInfo request)
  case pathInfo request of
    []            -> respondWith "static/dynamic.html" "text/html"
    ["style.css"] -> respondWith "static/style.css"  "text/css"
    ["index.js"]  -> respondWith "static/index.js"   "text/javascript"
    ["getnext"]   -> respond $ responseStream status200
                       [ ("Content-Type", "text/event-stream")
                       , ("Cache-Control", "no-cache")]
                       $ resultStream resultsSubscribe
    _ -> respond $ responseLBS status404
           [("Content-Type", "text/plain")] "404 - Not Found"
  where
    respondWith dataFname ctype = do
      fname <- return dataFname -- lets us skip rebuilding during development
      -- fname <- getDataFileName dataFname
      respond $ responseFile status200 [("Content-Type", ctype)] fname Nothing

type RenderedResultsServer = StateServer (MonoidState RenderedResults) RenderedResults
type RenderedResults = CellsUpdate RenderedSourceBlock RenderedOutputs

resultStream :: RenderedResultsServer -> StreamingBody
resultStream resultsServer write flush = do
  sendUpdate ("start"::String)
  (MonoidState initResult, resultsChan) <- subscribeIO resultsServer
  sendUpdate initResult
  forever $ readChan resultsChan >>= sendUpdate
  where
    sendUpdate :: ToJSON a => a -> IO ()
    sendUpdate x = write (fromByteString $ encodePacket x) >> flush

encodePacket :: ToJSON a => a -> BS.ByteString
encodePacket = toStrict . wrap . encode
  where wrap s = "data:" <> s <> "\n\n"

renderResults :: EvalServer -> IO RenderedResultsServer
renderResults evalServer = launchIncFunctionEvaluator evalServer
   (\x -> (MonoidState $ renderEvalUpdate $ nodeListAsUpdate x, ()))
   (\_ () dx -> (renderEvalUpdate dx, ()))

renderEvalUpdate :: CellsUpdate SourceBlock Outputs -> CellsUpdate RenderedSourceBlock RenderedOutputs
renderEvalUpdate cellsUpdate = fmapCellsUpdate cellsUpdate
  (\k b -> renderSourceBlock k b)
  (\_ r -> renderOutputs r)
