-- | Text frontend based on Vty.
module Game.LambdaHack.Client.UI.Frontend.Vty
  ( startup, frontendName
  ) where

import Prelude ()
import Prelude.Compat

import Control.Concurrent.Async
import Control.Monad
import Graphics.Vty
import qualified Graphics.Vty as Vty

import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.UI.Frontend.Common
import Game.LambdaHack.Client.UI.Overlay
import Game.LambdaHack.Common.ClientOptions
import qualified Game.LambdaHack.Common.Color as Color
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Point

-- | Session data maintained by the frontend.
data FrontendSession = FrontendSession
  { svty :: !Vty  -- ^ internal vty session
  }

-- | The name of the frontend.
frontendName :: String
frontendName = "vty"

-- | Starts the main program loop using the frontend input and output.
startup :: DebugModeCli -> IO RawFrontend
startup _sdebugCli = do
  svty <- mkVty mempty
  let sess = FrontendSession{..}
  rf <- createRawFrontend (display sess) (Vty.shutdown svty)
  let storeKeys :: IO ()
      storeKeys = do
        e <- nextEvent svty  -- blocks here, so no polling
        case e of
          EvKey n mods ->
            saveKMP rf (modTranslate mods) (keyTranslate n) originPoint
          _ -> return ()
        storeKeys
  void $ async storeKeys
  return $! rf

-- | Output to the screen via the frontend.
display :: FrontendSession    -- ^ frontend session data
        -> SingleFrame  -- ^ the screen frame to draw
        -> IO ()
display FrontendSession{svty} SingleFrame{sfLevel} =
  let img = (foldr (<->) emptyImage
             . map (foldr (<|>) emptyImage
                      . map (\Color.AttrChar{..} ->
                               char (setAttr acAttr) acChar)))
            $ overlay sfLevel
      pic = picForImage img
  in update svty pic

-- TODO: use http://hackage.haskell.org/package/vty-5.4.0/docs/Graphics-Vty-Config.html to remap keys internally
-- TODO: Ctrl-m is RET
keyTranslate :: Key -> K.Key
keyTranslate n =
  case n of
    KEsc          -> K.Esc
    KEnter        -> K.Return
    (KChar ' ')   -> K.Space
    (KChar '\t')  -> K.Tab
    KBackTab      -> K.BackTab
    KBS           -> K.BackSpace
    KUp           -> K.Up
    KDown         -> K.Down
    KLeft         -> K.Left
    KRight        -> K.Right
    KHome         -> K.Home
    KEnd          -> K.End
    KPageUp       -> K.PgUp
    KPageDown     -> K.PgDn
    KBegin        -> K.Begin
    KCenter       -> K.Begin
    KIns          -> K.Insert
    -- Ctrl-Home and Ctrl-End are the same in vty as Home and End
    -- on some terminals so we have to use 1--9 for movement instead of
    -- leader change.
    (KChar c)
      | c `elem` ['1'..'9'] -> K.KP c  -- movement, not leader change
      | otherwise           -> K.Char c
    _             -> K.Unknown (tshow n)

-- | Translates modifiers to our own encoding.
modTranslate :: [Modifier] -> K.Modifier
modTranslate mods =
  modifierTranslate
    (MCtrl `elem` mods) (MShift `elem` mods) (MAlt `elem` mods) False

-- A hack to get bright colors via the bold attribute. Depending on terminal
-- settings this is needed or not and the characters really get bold or not.
-- HSCurses does this by default, but in Vty you have to request the hack.
hack :: Color.Color -> Attr -> Attr
hack c a = if Color.isBright c then withStyle a bold else a

setAttr :: Color.Attr -> Attr
setAttr Color.Attr{..} =
-- This optimization breaks display for white background terminals:
--  if (fg, bg) == Color.defAttr
--  then def_attr
--  else
  let (fg1, bg1) = case bg of
        Color.BrRed -> (Color.defBG, Color.defFG)  -- highlighted tile
        Color.BrBlue ->  -- blue highlighted tile
          if fg /= Color.Blue
          then (fg, Color.Blue)
          else (fg, Color.BrBlack)
        Color.BrYellow ->  -- yellow highlighted tile
          if fg /= Color.BrBlack
          then (fg, Color.BrBlack)
          else (fg, Color.defFG)
        _ -> (fg, bg)
  in hack fg1 $ hack bg1 $
       defAttr { attrForeColor = SetTo (aToc fg1)
               , attrBackColor = SetTo (aToc bg1) }

aToc :: Color.Color -> Color
aToc Color.Black     = black
aToc Color.Red       = red
aToc Color.Green     = green
aToc Color.Brown     = yellow
aToc Color.Blue      = blue
aToc Color.Magenta   = magenta
aToc Color.Cyan      = cyan
aToc Color.White     = white
aToc Color.BrBlack   = brightBlack
aToc Color.BrRed     = brightRed
aToc Color.BrGreen   = brightGreen
aToc Color.BrYellow  = brightYellow
aToc Color.BrBlue    = brightBlue
aToc Color.BrMagenta = brightMagenta
aToc Color.BrCyan    = brightCyan
aToc Color.BrWhite   = brightWhite
