-- | Debug output for requests and responseQs.
module Game.LambdaHack.Server.DebugServer
  ( debugResponseAI, debugResponseUI
  , debugRequestAI, debugRequestUI
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Text.Show.Pretty as Show.Pretty

import Game.LambdaHack.Atomic
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.Response
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Server.MonadServer

-- We debug these on the server, not on the clients, because we want
-- a single log, knowing the order in which the server received requests
-- and sent responseQs. Clients interleave and block non-deterministically
-- so their logs would be harder to interpret.

debugShow :: Show a => a -> Text
debugShow = T.pack . Show.Pretty.ppShow

debugResponseAI :: MonadServer m => ResponseAI -> m ()
debugResponseAI cmd = case cmd of
  RespUpdAtomicAI cmdA@UpdPerception{} -> debugPlain cmd cmdA
  RespUpdAtomicAI cmdA@UpdResume{} -> debugPlain cmd cmdA
  RespUpdAtomicAI cmdA@UpdSpotTile{} -> debugPlain cmd cmdA
  RespUpdAtomicAI cmdA -> debugPretty cmd cmdA
  RespQueryAI aid -> do
    d <- debugAid aid "RespQueryAI" cmd
    serverPrint d

debugResponseUI :: MonadServer m => ResponseUI -> m ()
debugResponseUI cmd = case cmd of
  RespUpdAtomicUI cmdA@UpdPerception{} -> debugPlain cmd cmdA
  RespUpdAtomicUI cmdA@UpdResume{} -> debugPlain cmd cmdA
  RespUpdAtomicUI cmdA@UpdSpotTile{} -> debugPlain cmd cmdA
  RespUpdAtomicUI cmdA -> debugPretty cmd cmdA
  RespSfxAtomicUI sfx -> do
    ps <- posSfxAtomic sfx
    serverPrint $ debugShow (cmd, ps)
  RespQueryUI -> serverPrint $ "RespQueryUI:" <+> debugShow cmd

debugPretty :: (MonadServer m, Show a) => a -> UpdAtomic -> m ()
debugPretty cmd cmdA = do
  ps <- posUpdAtomic cmdA
  serverPrint $ debugShow (cmd, ps)

debugPlain :: (MonadServer m, Show a) => a -> UpdAtomic -> m ()
debugPlain cmd cmdA = do
  ps <- posUpdAtomic cmdA
  serverPrint $ T.pack $ show (cmd, ps)  -- too large for pretty printing

debugRequestAI :: MonadServer m => ActorId -> RequestAI -> m ()
debugRequestAI aid cmd = do
  d <- debugAid aid "AI request" cmd
  serverPrint d

debugRequestUI :: MonadServer m => ActorId -> RequestUI -> m ()
debugRequestUI aid cmd = do
  d <- debugAid aid "UI request" cmd
  serverPrint d

data DebugAid a = DebugAid
  { label   :: !Text
  , cmd     :: !a
  , lid     :: !LevelId
  , time    :: !Time
  , aid     :: !ActorId
  , faction :: !FactionId
  }
  deriving Show

debugAid :: (MonadStateRead m, Show a) => ActorId -> Text -> a -> m Text
debugAid aid label cmd = do
  b <- getsState $ getActorBody aid
  time <- getsState $ getLocalTime (blid b)
  return $! debugShow DebugAid { label
                               , cmd
                               , lid = blid b
                               , time
                               , aid
                               , faction = bfid b }
