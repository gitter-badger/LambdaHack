-- | Basic cartesian geometry operations on 2D points.
module Game.LambdaHack.PointXY
  ( -- * Geometry
    X, Y, PointXY(..), fromTo, sortPointXY
    -- * Assorted
  , normalLevelBound, Time, divUp
  ) where

import qualified Data.List as L

import Game.LambdaHack.Utils.Assert

-- | Spacial dimensions for points and vectors.
type X = Int
type Y = Int

-- | 2D points in cartesian representation.
newtype PointXY = PointXY (X, Y)
  deriving (Show, Eq, Ord)

-- | A list of all points on a straight vertical or horizontal line
-- between two points. Fails if no such line exists.
fromTo :: PointXY -> PointXY -> [PointXY]
fromTo (PointXY (x0, y0)) (PointXY (x1, y1)) =
 let result
       | x0 == x1 = L.map (\ y -> PointXY (x0, y)) (fromTo1 y0 y1)
       | y0 == y1 = L.map (\ x -> PointXY (x, y0)) (fromTo1 x0 x1)
       | otherwise = assert `failure` ((x0, y0), (x1, y1))
 in result

fromTo1 :: Int -> Int -> [Int]
fromTo1 x0 x1
  | x0 <= x1  = [x0..x1]
  | otherwise = [x0,x0-1..x1]

-- | Sort the collection of two points, in the derived lexicographic order.
sortPointXY :: (PointXY, PointXY) -> (PointXY, PointXY)
sortPointXY (a, b) | a <= b    = (a, b)
                   | otherwise = (b, a)

-- TODO: move all below somewhere else later on

-- | Level bounds. TODO: query terminal size instead and scroll view.
normalLevelBound :: (X, Y)
normalLevelBound = (79, 21)

-- | Game time in turns. The time dimension.
type Time = Int

-- | Integer division, rounding up.
divUp :: Int -> Int -> Int
divUp n k = (n + k - 1) `div` k
