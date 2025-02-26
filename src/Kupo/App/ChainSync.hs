--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE DuplicateRecordFields #-}

module Kupo.App.ChainSync
    ( ChainSyncHandler (..)
    , mkChainSyncClient
    , IntersectionNotFoundException (..)
    ) where

import Kupo.Prelude

import Kupo.Control.MonadThrow
    ( MonadThrow (..) )
import Kupo.Data.ChainSync
    ( Point (..), SlotNo (..), Tip (..), WithOrigin (..) )
import Network.TypedProtocol.Pipelined
    ( Nat (..), natToInt )
import Ouroboros.Network.Block
    ( getTipSlotNo, pointSlot )
import Ouroboros.Network.Protocol.ChainSync.ClientPipelined
    ( ChainSyncClientPipelined (..)
    , ClientPipelinedStIdle (..)
    , ClientPipelinedStIntersect (..)
    , ClientStNext (..)
    )

-- | Exception thrown when creating a chain-sync client from an invalid list of
-- points.
data IntersectionNotFoundException = IntersectionNotFoundException
    { points :: [WithOrigin SlotNo]
        -- ^ Provided points for intersection.
    , tip :: WithOrigin SlotNo
        -- ^ Current known tip of the chain.
    } deriving (Show)
instance Exception IntersectionNotFoundException

-- | A message handler for the chain-sync client. Messages are guaranteed (by
-- the protocol) to arrive in order.
data ChainSyncHandler m block = ChainSyncHandler
    { onRollBackward :: Point block -> m ()
    , onRollForward :: block -> m ()
    }

-- | A simple pipeline chain-sync clients which offers maximum pipelining and
-- defer handling of requests to callbacks.
mkChainSyncClient
    :: forall m block.
        ( MonadThrow m
        )
    => ChainSyncHandler m block
    -> [Point block]
    -> ChainSyncClientPipelined block (Point block) (Tip block) m ()
mkChainSyncClient ChainSyncHandler{onRollBackward, onRollForward} pts =
    ChainSyncClientPipelined (pure $ SendMsgFindIntersect pts clientStIntersect)
  where
    clientStIntersect
        :: ClientPipelinedStIntersect block (Point block) (Tip block) m ()
    clientStIntersect = ClientPipelinedStIntersect
        { recvMsgIntersectFound = \_point _tip -> do
            pure $ clientStIdle Zero
        , recvMsgIntersectNotFound = \(getTipSlotNo -> tip) -> do
            let points = pointSlot <$> pts
            throwIO $ IntersectionNotFoundException{points,tip}
        }

    clientStIdle
        :: forall n. ()
        => Nat n
        -> ClientPipelinedStIdle n block (Point block) (Tip block) m ()
    clientStIdle n = do
        SendMsgRequestNextPipelined $ CollectResponse
            (guard (natToInt n < maxInFlight) $> pure (clientStIdle $ Succ n))
            (clientStNext n)

    clientStNext
        :: forall n. ()
        => Nat n
        -> ClientStNext n block (Point block) (Tip block) m ()
    clientStNext n =
        ClientStNext
            { recvMsgRollForward = \block _tip ->
                onRollForward block $> clientStIdle n
            , recvMsgRollBackward = \point _tip ->
                onRollBackward point $> clientStIdle n
            }

-- | Maximum pipelining at any given time. No need to go too high here, it only
-- arms performance beyond a certain point.
--
-- TODO: Make this configurable as it depends on available machine's resources.
maxInFlight :: Int
maxInFlight = 100
