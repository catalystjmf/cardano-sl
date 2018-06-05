{-# LANGUAGE DeriveFunctor   #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Ranges
--
-- Intended for qualified import
module Util.Range (
    -- * Ranges
    Range(..)
  , Ranges(..)
  , SplitRanges(..)
  , rangeWithWidth
    -- ** Lenses
  , lo
  , hi
  , x
  , y
  , splitXRanges
  , splitYRange
    -- * Functions
  , containedIn
  , singleton
  , with
  , width
    -- * Gnuplot support
  , Reverse(..)
  , renderSplitAxis
  ) where

import           Universum

import           Control.Lens.TH (makeLenses)
import           Data.List (init)
import qualified Data.Text.Buildable
import           Formatting (bprint, build, sformat, (%))

{-------------------------------------------------------------------------------
  Ranges
-------------------------------------------------------------------------------}

-- | Range with a 'Buildable' instance that produces valid gnuplot output
data Range a = Range { _lo :: !a, _hi :: !a }
  deriving (Show, Functor)

-- | X-range and y-range
data Ranges a b = Ranges { _x :: !(Range a) , _y :: !(Range b) }
  deriving (Show)

instance Bifunctor Ranges where
  bimap f g Ranges{..} = Ranges (fmap f _x) (fmap g _y)

makeLenses ''Range
makeLenses ''Ranges

-- | Union two 'Range's
instance (Num a, Ord a) => Monoid (Range a) where
  mempty      = Range 0 0
  mappend a b = Range {
                    _lo = Universum.min (a ^. lo) (b ^. lo)
                  , _hi = Universum.max (a ^. hi) (b ^. hi)
                  }

-- | Union two 'Ranges'
instance (Num a, Ord a, Num b, Ord b) => Monoid (Ranges a b) where
  mempty      = Ranges mempty mempty
  mappend a b = Ranges {
                    _x = mappend (a ^. x) (b ^. x)
                  , _y = mappend (a ^. y) (b ^. y)
                  }

-- | Construct range from starting point and a width
rangeWithWidth :: Num a => a -> a -> Range a
rangeWithWidth l w = Range l (l + w)

{-------------------------------------------------------------------------------
  Functions
-------------------------------------------------------------------------------}

-- | Check if the specified point is in the given range
containedIn :: Ord a => Range a -> a -> Bool
containedIn Range{..} p = _lo <= p && p <= _hi

-- | Range containing a single point
singleton :: a -> Range a
singleton p = Range p p

-- | Grow the range (if necessary) so that it includes the specified point
with :: (Num a, Ord a) => a -> Range a -> Range a
with = mappend . singleton

-- | Width of the range
width :: Num a => Range a -> a
width Range{..} = _hi - _lo

{-------------------------------------------------------------------------------
  Split ranges
-------------------------------------------------------------------------------}

-- | Split ranges (for a broken x-axis)
--
-- NOTE: These fields are not strict; it's not a big deal since we don't
-- compose 'SplitRanges'.
data SplitRanges a b = SplitRanges {
      -- The pieces of the X range
      --
      -- For each piece we also record a weight; each subrange will be given
      -- a portion of the axis proportional to its weight.
      _splitXRanges :: [(Range a, Int)]

      -- The full (not split) Y range
    , _splitYRange  :: Range b
    }
  deriving (Show)

instance Bifunctor SplitRanges where
  bimap f g SplitRanges{..} = SplitRanges (map (first (fmap f)) _splitXRanges)
                                          (fmap g _splitYRange)

makeLenses ''SplitRanges

{-------------------------------------------------------------------------------
  Gnuplit support
-------------------------------------------------------------------------------}

-- | Output a range in reverse order
--
-- Useful for creating reverse axes
newtype Reverse a = Reverse (Range a)

instance Buildable a => Buildable (Reverse a) where
  build (Reverse Range{..}) = bprint ("[" % build % ":" % build % "]") _hi _lo

-- | Render range in gnuplot compatible syntax
instance Buildable a => Buildable (Range a) where
  build Range{..} = bprint ("[" % build % ":" % build % "]") _lo _hi

-- | Render a set of split ranges to a gnuplot broken x-axis
--
-- This function returns three things
--
-- * A prelude that defines two functions @f@ and @g@
--
--   > f(x) = ...
--   > g(x) = ...
--
--   This prelude should be included at the top of the gnuplot file.
--
-- * Instructions for setting up the x-axis (using @f@ and @g@)
-- * Instructions to tear it down again
--
-- See 'SplitRanges' for an explanation of the weight.
--
-- We take the binwidth as an additional parameter and extend the ranges
-- with half the binwidth, to avoid glitches when there are bins rendered
-- right at the edges of the ranges of the axis.
renderSplitAxis :: forall a. (Real a, Buildable a)
                => Int -> Double -> [(Range a, Int)] -> (Text, Text, Text)
renderSplitAxis binWidth gap xRanges = (
      sformat
        ( "f(x) = " % build % "\n"
        % "g(x) = " % build % "\n"
        )
        fnProj
        fnInv
    , sformat
        ( "set xrange " % build % "\n"
        % "set nonlinear x via f(x) inverse g(x)\n"
        % build
        )
        (mconcat (map fst xRanges))
        (mconcat $ zipWith showBreak [1 ..] (init (map fst xRanges)))
    , sformat
       ( "unset nonlinear x\n"
       % build
       )
       (mconcat $ zipWith resetBreak [1..] (init (map fst xRanges)))
    )
  where
    -- The total weight of all subranges
    -- We use this to compute the portion of the axis each subrange should get
    totalWeight :: Int
    totalWeight = sum (map snd xRanges)

    -- Total width of all subranges
    totalWidth :: a
    totalWidth = sum (map (width . fst) xRanges)

    -- Pair each subrange with its projected range on the split axis,
    -- as well as the portion that the projected range should take up
    -- on the number line
    zipWithProjRange :: [(Range a, Range Double, Double)]
                     -> [(Range a, Int)]
                     -> [(Range a, Range Double, Double)]
    zipWithProjRange acc []               = reverse acc
    zipWithProjRange acc ((r, weight):rs) =
        zipWithProjRange ((r,pr,fraction):acc) rs
      where
        -- projected range
        pr :: Range Double
        pr = case acc of
               []              -> rangeWithWidth 0                   projWidth
               ((_, pr', _):_) -> rangeWithWidth ((pr' ^. hi) + gap) projWidth

        -- TODO: This doesn't account for the gaps
        fraction :: Double
        fraction = (realToFrac totalWidth / realToFrac (width r))
                 * (fromIntegral weight / fromIntegral totalWeight)

        projWidth :: Double
        projWidth = fraction * realToFrac (width r)

    -- Check if a point is in the given range
    --
    -- We grow the range ever so slightly so that we don't miss points in the
    -- mapping due to rounding errors.
    checkInRange :: Real x => Range x -> Text
    checkInRange Range{..} =
        sformat
          ("(" % build % " <= x && x <= " % build % ")")
          ((ceiling :: Double -> Int) (realToFrac _lo - margin))
          ((floor   :: Double -> Int) (realToFrac _hi + margin))
      where
        -- see comment above regarding the binWidth argument
        margin = fromIntegral binWidth / 2

    -- Project a point from the original number line to the split number line
    projectToSplit :: (Range a, Range Double, Double) -> Text
    projectToSplit (r, pr, f) =
        sformat ("((x - " % build % ") * " % build % " + " % build % ")")
          (r  ^. lo)
          f
          (pr ^. lo)

    -- Project a point from the split number line to the original number line
    projectFromSplit :: (Range a, Range Double, Double) -> Text
    projectFromSplit (r, pr, f) =
        sformat ("((x - " % build % ") / " % build % " + " % build % ")")
          (pr ^. lo)
          f
          (r ^. lo)

    -- Gnuplot projection function
    fnProj :: Text
    fnProj =
        foldr
          (\(r, pr, f) alts ->
              sformat (build % " ? " % build % " : " % build)
                (checkInRange r)
                (projectToSplit (r, pr, f))
                alts)
          "NaN"
          (zipWithProjRange [] xRanges)

    -- Gnuplot inverse function
    fnInv :: Text
    fnInv =
        foldr
          (\(r, pr, f) alts ->
              sformat (build % " ? " % build % " : " % build)
                (checkInRange pr)
                (projectFromSplit (r, pr, f))
                alts)
          "NaN"
          (zipWithProjRange [] xRanges)

    -- Visually show break on the x-axzis
    showBreak :: Int -> Range a -> Text
    showBreak ix r =
        sformat
          ( "set arrow " % build
          % " from " % build
          % ", graph -0.02 length graph 0.04 angle 75 nohead lw 2 front\n"
          )
          ix
          (r ^. hi)

    -- Remove the break indicator
    resetBreak :: Int -> Range a -> Text
    resetBreak ix _r = sformat ("unset arrow " % build % "\n") ix