-- | Sending atomic commands to clients and executing them on the server.
-- See
-- <https://github.com/LambdaHack/LambdaHack/wiki/Client-server-architecture>.
module Game.LambdaHack.Atomic.BroadcastAtomicWrite
  ( handleAndBroadcast
  ) where

import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Key (mapWithKeyM_)
import Data.Maybe

import Game.LambdaHack.Atomic.CmdAtomic
import Game.LambdaHack.Atomic.HandleAtomicWrite
import Game.LambdaHack.Atomic.MonadStateWrite
import Game.LambdaHack.Atomic.PosAtomicRead
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Response
import Game.LambdaHack.Common.State
import Game.LambdaHack.Content.ModeKind

-- TODO: split into simpler pieces

--storeUndo :: MonadServer m => CmdAtomic -> m ()
--storeUndo _atomic =
--  maybe skip (\a -> modifyServer $ \ser -> ser {sundo = a : sundo ser})
--    $ Nothing   -- TODO: undoCmdAtomic atomic

handleCmdAtomicServer :: forall m. MonadStateWrite m
                      => PosAtomic -> CmdAtomic -> m ()
handleCmdAtomicServer posAtomic atomic =
  when (seenAtomicSer posAtomic) $
--    storeUndo atomic
    handleCmdAtomic atomic

-- | Send an atomic action to all clients that can see it.
handleAndBroadcast :: forall m a. MonadStateWrite m
                   => Bool -> Pers
                   -> (a -> FactionId -> LevelId -> m Perception)
                   -> m a
                   -> (FactionId -> ResponseAI -> m ())
                   -> (FactionId -> ResponseUI -> m ())
                   -> CmdAtomic
                   -> m ()
handleAndBroadcast knowEvents persOld doResetFidPerception doResetLitInDungeon
                   doSendUpdateAI doSendUpdateUI atomic = do
  -- Gather data from the old state.
  sOld <- getState
  factionD <- getsState sfactionD
  (ps, resets, atomicBroken, psBroken) <-
    case atomic of
      UpdAtomic cmd -> do
        ps <- posUpdAtomic cmd
        let resets = resetsFovCmdAtomic cmd
        atomicBroken <- breakUpdAtomic cmd
        psBroken <- mapM posUpdAtomic atomicBroken
        return (ps, resets, map UpdAtomic atomicBroken, psBroken)
      SfxAtomic sfx -> do
        ps <- posSfxAtomic sfx
        atomicBroken <- breakSfxAtomic sfx
        psBroken <- mapM posSfxAtomic atomicBroken
        return (ps, False, map SfxAtomic atomicBroken, psBroken)
  let atomicPsBroken = zip atomicBroken psBroken
  -- TODO: assert also that the sum of psBroken is equal to ps;
  -- with deep equality these assertions can be expensive; optimize.
  let !_A = assert (case ps of
                      PosSight{} -> True
                      PosFidAndSight{} -> True
                      PosFidAndSer (Just _) _ -> True
                      _ -> not resets
                   `blame` (ps, resets)) ()
  -- Perform the action on the server.
  handleCmdAtomicServer ps atomic
  -- Update lights in the dungeon. This is lazy, may not be needed
  -- or only partially; in particular not needed if not @resets@.
  -- This is needed every (even enemy) move to show thrown torches.
  persLit <- doResetLitInDungeon
  -- Send some actions to the clients, one faction at a time.
  let sendUI fid cmdUI =
        when (fhasUI $ gplayer $ factionD EM.! fid) $ doSendUpdateUI fid cmdUI
      sendAI = doSendUpdateAI
      sendA fid cmd = do
        sendUI fid $ RespUpdAtomicUI cmd
        sendAI fid $ RespUpdAtomicAI cmd
      sendUpdate fid (UpdAtomic cmd) = sendA fid cmd
      sendUpdate fid (SfxAtomic sfx) = sendUI fid $ RespSfxAtomicUI sfx
      breakSend lid fid perNew = do
        let send2 (atomic2, ps2) =
              if seenAtomicCli knowEvents fid perNew ps2
                then sendUpdate fid atomic2
                else do
                  mleader <- getsState $ gleader . (EM.! fid) . sfactionD
                  case (atomic2, mleader) of
                    (UpdAtomic cmd, Just (leader, _)) -> do
                      body <- getsState $ getActorBody leader
                      loud <- loudUpdAtomic (blid body == lid) fid cmd
                      case loud of
                        Nothing -> return ()
                        Just msg -> sendUpdate fid $ SfxAtomic $ SfxMsgAll msg
                    _ -> return ()
        mapM_ send2 atomicPsBroken
      anySend lid fid perOld perNew = do
        let startSeen = seenAtomicCli knowEvents fid perOld ps
            endSeen = seenAtomicCli knowEvents fid perNew ps
        if startSeen && endSeen
          then sendUpdate fid atomic
          else breakSend lid fid perNew
      posLevel fid lid = do
        let perOld = persOld EM.! fid EM.! lid
        if resets then do
          -- Needed every move to show thrown torches in dark corridors.
          perNew <- doResetFidPerception persLit fid lid
          let inPer = diffPer perNew perOld
              outPer = diffPer perOld perNew
          if nullPer outPer && nullPer inPer
            then anySend lid fid perOld perOld
            else do
              unless knowEvents $ do  -- inconsistencies would quickly manifest
                sendA fid $ UpdPerception lid outPer inPer
                let remember = atomicRemember lid inPer sOld
                    seenNew = seenAtomicCli False fid perNew
                    seenOld = seenAtomicCli False fid perOld
                psRem <- mapM posUpdAtomic remember
                -- Verify that we remember only currently seen things.
                let !_A = assert (allB seenNew psRem) ()
                -- Verify that we remember only new things.
                let !_A = assert (allB (not . seenOld) psRem) ()
                mapM_ (sendA fid) remember
              anySend lid fid perOld perNew
        else anySend lid fid perOld perOld
      send fid = case ps of
        PosSight lid _ -> posLevel fid lid
        PosFidAndSight _ lid _ -> posLevel fid lid
        -- In the following cases, from the assertion above,
        -- @resets@ is false here and broken atomic has the same ps.
        PosSmell lid _ -> do
          let perOld = persOld EM.! fid EM.! lid
          anySend lid fid perOld perOld
        PosFid fid2 -> when (fid == fid2) $ sendUpdate fid atomic
        PosFidAndSer Nothing fid2 -> when (fid == fid2) $ sendUpdate fid atomic
        PosFidAndSer (Just lid) _ -> posLevel fid lid
        PosSer -> return ()
        PosAll -> sendUpdate fid atomic
        PosNone -> return ()
  mapWithKeyM_ (\fid _ -> send fid) factionD

atomicRemember :: LevelId -> Perception -> State -> [UpdAtomic]
atomicRemember lid inPer s =
  -- No @UpdLoseItem@ is sent for items that became out of sight.
  -- The client will create these atomic actions based on @outPer@,
  -- if required. Any client that remembers out of sight items, OTOH,
  -- will create atomic actions that forget remembered items
  -- that are revealed not to be there any more (no @UpdSpotItem@ for them).
  -- Similarly no @UpdLoseActor@, @UpdLoseTile@ nor @UpdLoseSmell@.
  let inFov = ES.elems $ totalVisible inPer
      lvl = sdungeon s EM.! lid
      -- Actors.
      carriedAssocs b = getCarriedAssocs b s
      inPrio = concatMap (\p -> posToActors p lid s) inFov
      fActor (aid, b) =
        let ais = carriedAssocs b
        in UpdSpotActor aid b ais
      inActor = map fActor inPrio
      -- Items.
      pMaybe p = maybe Nothing (\x -> Just (p, x))
      inContainer fc itemFloor =
        let inItem = mapMaybe (\p -> pMaybe p $ EM.lookup p itemFloor) inFov
            fItem p (iid, kit) =
              UpdSpotItem iid (getItemBody iid s) kit (fc lid p)
            fBag (p, bag) = map (fItem p) $ EM.assocs bag
        in concatMap fBag inItem
      inFloor = inContainer CFloor (lfloor lvl)
      inEmbed = inContainer CEmbed (lembed lvl)
      -- Tiles.
      inTileMap = map (\p -> (p, hideTile (scops s) lvl p)) inFov
      atomicTile = if null inTileMap then [] else [UpdSpotTile lid inTileMap]
      -- Smells.
      inSmellFov = ES.elems $ smellVisible inPer
      inSm = mapMaybe (\p -> pMaybe p $ EM.lookup p (lsmell lvl)) inSmellFov
      atomicSmell = if null inSm then [] else [UpdSpotSmell lid inSm]
  in inFloor ++ inEmbed ++ inActor ++ atomicTile ++ atomicSmell
