{-# LANGUAGE CPP        #-}
{-# LANGUAGE RankNTypes #-}

-- | High-level scenarios which can be launched.

module Pos.Launcher.Scenario
       ( runNode
       , runNode'
       , nodeStartMsg
       ) where

import           Universum

import           Control.Exception.Safe (withException)
import qualified Data.HashMap.Strict as HM
import           Formatting (bprint, build, int, sformat, shown, (%))
import           Mockable (mapConcurrently)
import           Serokell.Util (listJson)
import           System.Wlog (WithLogger, askLoggerName, logDebug, logInfo, logWarning)

import           Pos.Communication (OutSpecs)
import           Pos.Communication.Util (ActionSpec (..), wrapActionSpec)
import           Pos.Context (getOurPublicKey)
import           Pos.Core (GenesisData (gdBootStakeholders, gdHeavyDelegation),
                           GenesisDelegation (..), GenesisWStakeholders (..), addressHash,
                           gdFtsSeed, genesisData)
import           Pos.Crypto (pskDelegatePk)
import qualified Pos.DB.BlockIndex as DB
import qualified Pos.GState as GS
import           Pos.Launcher.Resource (NodeResources (..))
import           Pos.NtpCheck (NtpStatus (..), ntpSettings, withNtpCheck)
import           Pos.Reporting (reportError)
import           Pos.Slotting (waitSystemStart)
import           Pos.Txp (bootDustThreshold)
import           Pos.Update.Configuration (HasUpdateConfiguration, curSoftwareVersion,
                                           lastKnownBlockVersion, ourSystemTag)
import           Pos.Util.AssertMode (inAssertMode)
import           Pos.Util.CompileInfo (HasCompileInfo, compileInfo)
import           Pos.Util.LogSafe (logInfoS)
import           Pos.Worker (allWorkers)
import           Pos.Worker.Types (WorkerSpec)
import           Pos.WorkMode.Class (WorkMode)

-- | Entry point of full node.
-- Initialization, running of workers, running of plugins.
runNode'
    :: forall ext ctx m.
       ( HasCompileInfo, WorkMode ctx m
       )
    => NodeResources ext
    -> [WorkerSpec m]
    -> [WorkerSpec m]
    -> WorkerSpec m
runNode' NodeResources {..} workers' plugins' = ActionSpec $ \diffusion -> ntpCheck $ do
    logInfo $ "Built with: " <> pretty compileInfo
    nodeStartMsg
    inAssertMode $ logInfo "Assert mode on"
    pk <- getOurPublicKey
    let pkHash = addressHash pk
    logInfoS $ sformat ("My public key is: "%build%", pk hash: "%build)
        pk pkHash

    let genesisStakeholders = gdBootStakeholders genesisData
    logInfo $ sformat
        ("Genesis stakeholders ("%int%" addresses, dust threshold "%build%"): "%build)
        (length $ getGenesisWStakeholders genesisStakeholders)
        bootDustThreshold
        genesisStakeholders

    let genesisDelegation = gdHeavyDelegation genesisData
    let formatDlgPair (issuerId, delegateId) =
            bprint (build%" -> "%build) issuerId delegateId
    logInfo $ sformat ("GenesisDelegation (stakeholder ids): "%listJson)
            $ map (formatDlgPair . second (addressHash . pskDelegatePk))
            $ HM.toList
            $ unGenesisDelegation genesisDelegation

    firstGenesisHash <- GS.getFirstGenesisBlockHash
    logInfo $ sformat
        ("First genesis block hash: "%build%", genesis seed is "%build)
        firstGenesisHash
        (gdFtsSeed genesisData)

    tipHeader <- DB.getTipHeader
    logInfo $ sformat ("Current tip header: "%build) tipHeader

    waitSystemStart
    let unpackPlugin (ActionSpec action) =
            action diffusion `withException` reportHandler

    void (mapConcurrently (unpackPlugin) $ workers' ++ plugins')

    exitFailure

  where
    -- REPORT:ERROR Node's worker/plugin failed with exception (which wasn't caught)
    reportHandler (SomeException e) = do
        loggerName <- askLoggerName
        reportError $
            sformat ("Worker/plugin with logger name "%shown%
                    " failed with exception: "%shown)
            loggerName e
    ntpCheck = withNtpCheck $ ntpSettings onNtpStatusLogWarning

-- | Entry point of full node.
-- Initialization, running of workers, running of plugins.
runNode
    :: ( HasCompileInfo
       , WorkMode ctx m
       )
    => NodeResources ext
    -> ([WorkerSpec m], OutSpecs)
    -> (WorkerSpec m, OutSpecs)
runNode nr (plugins, plOuts) =
    (, plOuts <> wOuts) $ runNode' nr workers' plugins'
  where
    (workers', wOuts) = allWorkers nr
    plugins' = map (wrapActionSpec "plugin") plugins

onNtpStatusLogWarning :: WithLogger m => NtpStatus -> m ()
onNtpStatusLogWarning = \case
    NtpSyncOk -> logDebug $
              -- putText  $ -- FIXME: for some reason this message isn't printed
                            -- when using 'logDebug', but a simple 'putText' works
                            -- just fine.
        "Local time is in sync with the NTP server"
    NtpDesync diff -> logWarning $
        "Local time is severely off sync with the NTP server: " <> show diff

-- | This function prints a very useful message when node is started.
nodeStartMsg :: (HasUpdateConfiguration, WithLogger m) => m ()
nodeStartMsg = logInfo msg
  where
    msg = sformat ("Application: " %build% ", last known block version "
                    %build% ", systemTag: " %build)
                   curSoftwareVersion
                   lastKnownBlockVersion
                   ourSystemTag
