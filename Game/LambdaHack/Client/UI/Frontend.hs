{-# LANGUAGE GADTs, KindSignatures, RankNTypes #-}
-- | Display game data on the screen and receive user input
-- using one of the available raw frontends and derived operations.
module Game.LambdaHack.Client.UI.Frontend
  ( -- * Connection types
    FrontReq(..), ChanFrontend(..), KMP, kmpKeyMod, kmpPointer
    -- * Re-exported part of the raw frontend
  , frontendName
    -- * Derived operations
  , chanFrontend
  ) where

import Control.Concurrent
import Control.Concurrent.Async
import qualified Control.Concurrent.STM as STM
import Control.Exception.Assert.Sugar
import Control.Monad (unless, when)
import Data.IORef
import Data.Maybe

import qualified Game.LambdaHack.Client.Key as K
import qualified Game.LambdaHack.Client.UI.Frontend.Chosen as Chosen
import Game.LambdaHack.Client.UI.Frontend.Common
import qualified Game.LambdaHack.Client.UI.Frontend.Std as Std
import Game.LambdaHack.Client.UI.Overlay
import Game.LambdaHack.Common.ClientOptions
import Game.LambdaHack.Common.Point

-- | The instructions sent by clients to the raw frontend.
data FrontReq :: * -> * where
  FrontFrame :: {frontFrame :: !SingleFrame} -> FrontReq ()
    -- ^ show a frame
  FrontDelay :: !Int -> FrontReq ()
    -- ^ perform an explicit delay of the given length
  FrontKey :: { frontKeyKeys  :: ![K.KM]
              , frontKeyFrame :: !SingleFrame } -> FrontReq KMP
    -- ^ flush frames, display a frame and ask for a keypress
  FrontPressed :: FrontReq Bool
    -- ^ inspect the fkeyPressed MVar
  FrontDiscard :: FrontReq ()
    -- ^ discard a key in the queue; fail if queue empty
  FrontAutoYes :: Bool -> FrontReq ()
    -- ^ set in the frontend that it should auto-answer prompts
  FrontShutdown :: FrontReq ()
    -- ^ shut the frontend down

-- | Connection channel between a frontend and a client. Frontend acts
-- as a server, serving keys, etc., when given frames to display.
newtype ChanFrontend = ChanFrontend (forall a. FrontReq a -> IO a)

data FSession = FSession
  { fautoYesRef   :: !(IORef Bool)
  , fasyncTimeout :: !(Async ())
  , fdelay        :: !(MVar Int)
  }

-- | Display a prompt, wait for any of the specified keys (for any key,
-- if the list is empty). Repeat if an unexpected key received.
getKey :: DebugModeCli -> FSession -> RawFrontend -> [K.KM] -> SingleFrame
       -> IO KMP
getKey sdebugCli fs rf@RawFrontend{fchanKey} keys frame = do
  autoYes <- readIORef $ fautoYesRef fs
  if autoYes && K.spaceKM `K.elemOrNull` keys then do
    display rf frame
    return $! KMP{kmpKeyMod = K.spaceKM, kmpPointer=originPoint}
  else do
    -- Wait until timeout is up, not to skip the last frame of animation.
    display rf frame
    kmp <- STM.atomically $ STM.readTQueue fchanKey
    if kmpKeyMod kmp `K.elemOrNull` keys
    then return kmp
    else getKey sdebugCli fs rf keys frame

-- | Read UI requests from the client and send them to the frontend,
fchanFrontend :: DebugModeCli -> FSession -> RawFrontend -> ChanFrontend
fchanFrontend sdebugCli fs@FSession{..} rf =
  ChanFrontend $ \req -> case req of
    FrontFrame{..} -> display rf frontFrame
    FrontDelay k -> modifyMVar_ fdelay $ return . (+ k)
    FrontKey{..} -> getKey sdebugCli fs rf frontKeyKeys frontKeyFrame
    FrontPressed -> do
      noKeysPending <- STM.atomically $ STM.isEmptyTQueue (fchanKey rf)
      return $! not noKeysPending
    FrontDiscard -> do
      mkey <- STM.atomically $ STM.tryReadTQueue (fchanKey rf)
      when (isNothing mkey) $
        assert `failure` "empty queue of pressed keys" `twith` ()
    FrontAutoYes b -> writeIORef fautoYesRef b
    FrontShutdown -> do
      cancel fasyncTimeout
      fshutdown rf

display :: RawFrontend -> SingleFrame -> IO ()
display rf@RawFrontend{fshowNow} frontFrame = do
  putMVar fshowNow () -- 1. wait for permission to display; 3. ack
  fdisplay rf frontFrame

defaultMaxFps :: Int
defaultMaxFps = 30

microInSec :: Int
microInSec = 1000000

-- This thread is canceled forcefully, because the @threadDelay@
-- may be much longer than an acceptable shutdown time.
frameTimeoutThread :: Int -> MVar Int -> RawFrontend -> IO ()
frameTimeoutThread delta fdelay RawFrontend{..} = do
  let loop = do
        threadDelay delta
        let delayLoop = do
              delay <- readMVar fdelay
              when (delay > 0) $ do
                threadDelay $ delta * delay
                modifyMVar_ fdelay $ return . subtract delay
                delayLoop
        delayLoop
        let waitForKeysUsed = do
              -- @fshowNow@ is full at this point, unless @saveKM@ emptied it,
              -- in which case we wait below until @display@ fills it
              takeMVar fshowNow  -- 2. permit display
              -- @fshowNow@ is ever empty only here, unless @saveKM@ empties it
              readMVar fshowNow  -- 4. wait for ack before starting delay
              -- @fshowNow@ is full at this point
              noKeysPending <- STM.atomically $ STM.isEmptyTQueue fchanKey
              unless noKeysPending waitForKeysUsed
        waitForKeysUsed
        loop
  loop

-- | The name of the chosen frontend.
frontendName :: String
frontendName = Chosen.frontendName

nullStartup :: IO RawFrontend
nullStartup = createRawFrontend (\_ -> return ()) (return ())

chanFrontend :: DebugModeCli -> IO ChanFrontend
chanFrontend sdebugCli = do
  let startup | sfrontendNull sdebugCli = nullStartup
              | sfrontendStd sdebugCli = Std.startup sdebugCli
              | otherwise = Chosen.startup sdebugCli
      maxFps = fromMaybe defaultMaxFps $ smaxFps sdebugCli
      delta = microInSec `div` maxFps
  rf <- startup
  fautoYesRef <- newIORef $ not $ sdisableAutoYes sdebugCli
  fdelay <- newMVar 0
  fasyncTimeout <- async $ frameTimeoutThread delta fdelay rf
  -- Warning: not linking @fasyncTimeout@, so it'd better not crash.
  let fs = FSession{..}
  return $ fchanFrontend sdebugCli fs rf
