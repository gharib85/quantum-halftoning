{-# LANGUAGE TypeSynonymInstances, TypeFamilies, RecordWildCards, LambdaCase, UnicodeSyntax #-}

import Data.Foldable
import Control.Monad

import Data.List.Split
import Numeric.Natural
import Data.Word
import Control.Monad.Except

import Foreign.Storable
import Control.Concurrent
import Control.Monad.ST
import System.Random

import qualified Data.Vector.Storable         as V
import qualified Data.Vector.Storable.Mutable as MV

import Graphics.Gloss

import Codec.Picture hiding (Image(..))
import qualified Codec.Picture as JP
import Codec.Picture.Types hiding (Image(..))
import Codec.Picture.Metadata
import GHC.Float

import System.Environment
import System.Exit
import Text.Read

--------------------------------------------------------------------------------

type 𝔹 = Bool
type ℕ = Natural
type ℝ = Double

(<&>) ∷ Functor f ⇒ f a → (a → b) → f b
(<&>) = flip (<$>)
infixl 1 <&>
{-# INLINABLE (<&>) #-}

--------------------------------------------------------------------------------

data Image a = Image { width  ∷ !Int
                     , height ∷ !Int
                     , pixels ∷ !(V.Vector a) }
             deriving (Eq, Ord, Show, Read)

at ∷ Storable a ⇒ Image a → Int → Int → a
at Image{..} x y | x < width && y < height = pixels `V.unsafeIndex` (x + y*width)
                 | otherwise               = error $  "Image index "   ++ show (x,y)
                                                   ++ " out of range " ++ show (width,height)
{-# INLINABLE at #-}

forCoordinates_ ∷ (Enum x, Num x, Enum y, Num y, Applicative f)
                ⇒ x → y → (x → y → f ()) → f ()
forCoordinates_ xSize ySize act =
  for_ [0..ySize-1] $ \y →
    for_ [0..xSize-1] $ \x →
      act x y
{-# INLINABLE forCoordinates_ #-}
{-# SPECIALIZE forCoordinates_ ∷ Int → Int → (Int → Int → ST s ()) → ST s () #-}
{-# SPECIALIZE forCoordinates_ ∷ Int → Int → (Int → Int → IO   ()) → IO   () #-}

expandWith ∷ Storable a ⇒ ℕ → (a → a) → Image a → Image a
expandWith nNat f img@Image{..} =
  let n | nNat > fromIntegral (maxBound ∷ Int) = error "expandWith: scale factor out of range"
        | otherwise                            = fromIntegral nNat
      
      width'  = n*width
      height' = n*height
      pixels' = V.create $ do
                  pixels' ← MV.new $ width' * height'
                  forCoordinates_ width height $ \x y →
                    let value = f $ at img x y
                        dest' = n*x + n*y*width'
                    in forCoordinates_ n n $ \dx dy →
                         MV.write pixels' (dest' + dx + width'*dy) value
                  pure pixels'
  in Image { width = width', height = height', pixels = pixels' }

toLists ∷ Storable a ⇒ Image a → [[a]]
toLists Image{..} = chunksOf width $ V.toList pixels

--------------------------------------------------------------------------------

coin ∷ ℝ → IO 𝔹
coin p = (< p) <$> randomIO

--------------------------------------------------------------------------------

build ∷ Image ℝ → IO (MV.IOVector Word8)
build img@Image{..} = do
  vec ← MV.new $ 4*width*height
  forCoordinates_ width height $ refresh img vec
  pure vec

refresh ∷ Image ℝ → MV.IOVector Word8 → Int → Int → IO ()
refresh img vec x y = do
  let index = x + width img * y
  value ← coin (at img x y) <&> \case
             True  → 0
             False → 255
  MV.write vec (4*index + 0) value
  MV.write vec (4*index + 1) value
  MV.write vec (4*index + 2) value
  MV.write vec (4*index + 3) 255

randomIndex ∷ Image ℝ → IO (Int,Int)
randomIndex Image{..} = (,) <$> randomRIO (0, width-1) <*> randomRIO (0, height-1)

refreshRandom ∷ Image ℝ → MV.IOVector Word8 → IO ()
refreshRandom img vec = uncurry (refresh img vec) =<< randomIndex img

--------------------------------------------------------------------------------

probability ∷ ℕ → Maybe (ℝ → ℝ)
probability 1  = Just $
  \case x | x < 1/2   → 0
          | otherwise → 1

probability 4  = Just $
  \case x | x < 1/3   → 0
          | x < 2/3   → 0.5
          | otherwise → 1

probability 9  = Just $
  \case x | x < 1/3   → 0
          | x < 2/3   → 0.5
          | otherwise → 1

probability 16 = Just $
  \case x | x < 1/3   → 0
          | x < 2/3   → 0.5
          | otherwise → 1

probability 25 = Just $
  \case x | x < 1/3   → 0
          | x < 2/3   → 0.5
          | otherwise → 1

probability 36 = Just $
  \case x | x < 1/3   → 0
          | x < 2/3   → 0.5
          | otherwise → 1

probability _  = Nothing

--------------------------------------------------------------------------------

class Pixel a ⇒ ToGrayscale a where
  grayscale       ∷ a → ℝ
  grayscaleVector ∷ Metadatas → JP.Image a → V.Vector ℝ

instance ToGrayscale Pixel8 where
  grayscale       = wordGrayscale
  grayscaleVector = plainGrayscaleVector

instance ToGrayscale Pixel16 where
  grayscale       = wordGrayscale
  grayscaleVector = plainGrayscaleVector

instance ToGrayscale Pixel32 where
  grayscale       = wordGrayscale
  grayscaleVector = plainGrayscaleVector

instance ToGrayscale PixelF where
  grayscale       = float2Double
  grayscaleVector = plainGrayscaleVector

wordGrayscale ∷ (Integral g, Bounded g) ⇒ g → ℝ
wordGrayscale g = fromIntegral g / fromIntegral (maxBound `asTypeOf` g)
{-# INLINABLE wordGrayscale #-}

plainGrayscaleVector ∷ (ToGrayscale a, a ~ PixelBaseComponent a) ⇒ Metadatas → JP.Image a → V.Vector ℝ
plainGrayscaleVector _ JP.Image{..} = V.map grayscale imageData
{-# INLINABLE plainGrayscaleVector #-}

grayscaleImage ∷ ToGrayscale a ⇒ Metadatas → JP.Image a → Image ℝ
grayscaleImage md img@JP.Image{..} = Image { width  = imageWidth
                                           , height = imageHeight
                                           , pixels = grayscaleVector md img }

readGrayscale ∷ FilePath → ExceptT String IO (Image ℝ)
readGrayscale file = do
  (dimg, md) ← ExceptT $ readImageWithMetadata file
  case dimg of
    ImageY8  img → pure $ grayscaleImage md img
    ImageY16 img → pure $ grayscaleImage md img
    ImageYF  img → pure $ grayscaleImage md img
    _            → throwError "Non-grayscale image format"

--------------------------------------------------------------------------------

mainWith ∷ ℕ → Int → FilePath → IO ()
mainWith n freq file = do
  coinWeight    ← maybe (die "Unknown expansion factor") pure $ probability (n*n)
  probabilities ← either die (pure . expandWith n coinWeight)
                    =<< runExceptT (readGrayscale file)
  bitVector     ← build probabilities
  let bitmap = bitmapOfForeignPtr (width probabilities) (height probabilities)
                                  (BitmapFormat TopToBottom PxRGBA)
                                  (fst $ MV.unsafeToForeignPtr0 bitVector)
                                  False
  
  void . forkIO . forever $ do
    threadDelay   freq
    refreshRandom probabilities bitVector
  
  animate (InWindow "Quantum Halftoning"
                    (width probabilities, height probabilities)
                    (100,100))
          (greyN 0.5)
          (const bitmap)

main ∷ IO ()
main = getArgs >>= \case
  [nStr, freqStr, file] → do
    let parse what = maybe (die $ "Could not parse " ++ what) pure . readMaybe
    n    ← parse "expansion factor" nStr
    freq ← parse "refresh rate"     freqStr
    mainWith n freq file
  _ → do
    name ← getProgName
    die $ "Usage: " ++ name ++ " N FREQ FILE"
