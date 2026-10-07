use std::path::PathBuf;
use std::sync::Arc;

use serde_json::Value;

use operit_model::FunctionType::FunctionType;
use operit_model::MemorySearchConfig::MemorySearchConfig;
use operit_model::ModelConfigData::{ProviderProfile, ResolvedModelConfig};
use operit_model::PromptFunctionType::PromptFunctionType;
use operit_plugin_sdk::toolpkg::ToolPkgHooks::{
    decodeToolPkgHookResult, ToolPkgAiProviderRegistration,
};
use operit_providers::runtime_support::{
    ProviderCharacterPromptContext, ProviderFunctionModelBinding, ProviderMemoryAutoSaveMessage,
    ProviderMessageTiming, ProviderPackageInfo, ProviderRuntimeContext, ProviderRuntimeSupport,
    ProviderRuntimeSupportFuture, ProviderToolPkgAiProviderRegistration,
};
use operit_tools::tools::skill_runtime::SkillRepository::SkillRepository;
use operit_tools::tools::AIToolHandler::AIToolHandler;

use crate::data::preferences::ApiPreferences::ApiPreferences;
use crate::data::preferences::CharacterCardManager::CharacterCardManager;
use crate::data::preferences::FunctionalConfigManager::FunctionalConfigManager;
use crate::data::preferences::MemorySearchSettingsPreferences::MemorySearchSettingsPreferences;
use crate::data::preferences::ModelConfigManager::ModelConfigManager;
use crate::data::preferences::SharedMemoryStoreManager::SharedMemoryStoreManager;
use crate::plugins::toolpkg::ToolPkgAiProviderRegistry::ToolPkgAiProviderRegistry;
use operit_model::CharacterCard::CharacterCardMemoryBindingMode;
use operit_store::repository::ChatHistoryManager::ChatHistoryManager;
use operit_store::RuntimeStorePaths::RuntimeStorePaths;
use operit_util::OperitPaths::{characterMemoryOwnerKey, sharedMemoryOwnerKey};

/// Creates runtime-backed services required by provider crates.
pub struct ProviderRuntimeSupportService;

impl ProviderRuntimeSupportService {
    /// Creates provider runtime support bound to one tool handler instance.
    pub fn create(tool_handler: AIToolHandler) -> ProviderRuntimeContext {
        ProviderRuntimeContext::new(Arc::new(RuntimeProviderSupport { tool_handler }))
    }
}

/// Bridges provider-owned interfaces to runtime-owned managers and registries.
struct RuntimeProviderSupport {
    tool_handler: AIToolHandler,
}

impl ProviderRuntimeSupport for RuntimeProviderSupport {
    /// Returns the root directory used by runtime data.
    fn dataDir(&self) -> Result<PathBuf, String> {
        Ok(ApiPreferences::data_dir())
    }

    /// Returns the current thinking quality level.
    fn thinkingQualityLevel(&self) -> Result<i32, String> {
        ApiPreferences::getInstance()
            .thinkingQualityLevelFlow()
            .first()
            .map_err(|error| error.to_string())
    }

    /// Records provider/model token usage.
    fn updateTokensForProviderModel(
        &self,
        providerModel: &str,
        inputTokens: i64,
        outputTokens: i64,
        cachedInputTokens: i64,
    ) -> Result<(), String> {
        ApiPreferences::getInstance()
            .updateTokensForProviderModel(
                providerModel,
                inputTokens,
                outputTokens,
                cachedInputTokens,
            )
            .map_err(|error| error.to_string())
    }

    /// Loads memory search settings for an owner key.
    fn memorySearchConfig(&self, ownerKey: &str) -> Result<MemorySearchConfig, String> {
        MemorySearchSettingsPreferences::new(ownerKey)
            .load()
            .map_err(|error| error.to_string())
    }

    fn disableUserPreferenceDescription(&self) -> Result<bool, String> {
        Ok(crate::data::preferences::ApiPreferences::ApiPreferences::getInstance()
            .disableUserPreferenceDescriptionFlow().first().map_err(|e|e.to_string())?)
    }

    /// Resolves the owner key selected by one character card.
    fn memoryOwnerKeyForCharacterCard(&self, roleCardId: &str) -> Result<String, String> {
        let card = CharacterCardManager::getInstance()
            .getCharacterCard(roleCardId)
            .map_err(|error| error.to_string())?;
        if CharacterCardMemoryBindingMode::normalize(Some(&card.memoryBindingMode))
            == CharacterCardMemoryBindingMode::SHARED
        {
            let sharedId = card
                .sharedMemoryId
                .as_deref()
                .ok_or_else(|| "shared memory binding requires sharedMemoryId".to_string())?;
            sharedMemoryOwnerKey(sharedId)
        } else {
            characterMemoryOwnerKey(&card.id)
        }
    }

    /// Lists character and shared memory owners visible to the runtime.
    fn memoryAutoSaveOwnerKeys(&self) -> Result<Vec<String>, String> {
        let mut ownerKeys = Vec::new();
        for card in CharacterCardManager::getInstance()
            .getAllCharacterCards()
            .map_err(|error| error.to_string())?
        {
            ownerKeys.push(self.memoryOwnerKeyForCharacterCard(&card.id)?);
        }
        for store in SharedMemoryStoreManager::getInstance().getAllSharedMemoryStores()? {
            ownerKeys.push(sharedMemoryOwnerKey(&store.id)?);
        }
        ownerKeys.sort();
        ownerKeys.dedup();
        Ok(ownerKeys)
    }

    /// Loads hydrated messages before one trigger timestamp for provider background work.
    fn memoryAutoSaveMessagesBefore(
        &self,
        chatId: &str,
        maxTimestampInclusive: i64,
        limit: usize,
    ) -> Result<Vec<ProviderMemoryAutoSaveMessage>, String> {
        let manager = ChatHistoryManager::getInstance(RuntimeStorePaths::default())
            .map_err(|error| error.to_string())?;
        manager
            .loadChatMessagesDescUpTo(chatId.to_string(), maxTimestampInclusive, limit as i32)
            .map_err(|error| error.to_string())
            .map(|messages| {
                messages
                    .into_iter()
                    .map(|message| {
                        let content = message.displayText();
                        ProviderMemoryAutoSaveMessage {
                            timestamp: message.timestamp,
                            sender: message.sender,
                            content,
                        }
                    })
                    .collect()
            })
    }

    /// Loads hydrated messages for explicitly selected timestamps.
    fn memoryAutoSaveMessagesByTimestamps(
        &self,
        chatId: &str,
        timestamps: &[i64],
    ) -> Result<Vec<ProviderMemoryAutoSaveMessage>, String> {
        let manager = ChatHistoryManager::getInstance(RuntimeStorePaths::default())
            .map_err(|error| error.to_string())?;
        manager
            .loadChatMessages(chatId)
            .map_err(|error| error.to_string())
            .map(|messages| {
                messages
                    .into_iter()
                    .filter(|message| timestamps.contains(&message.timestamp))
                    .map(|message| {
                        let content = message.displayText();
                        ProviderMemoryAutoSaveMessage {
                            timestamp: message.timestamp,
                            sender: message.sender,
                            content,
                        }
                    })
                    .collect()
            })
    }

    /// Resolves character prompt data for a selected role card.
    fn characterPromptContext(
        &self,
        roleCardId: &str,
        promptFunctionType: PromptFunctionType,
    ) -> Result<ProviderCharacterPromptContext, String> {
        let manager = CharacterCardManager::getInstance();
        let activeCard = manager
            .getCharacterCard(roleCardId)
            .map_err(|error| error.to_string())?;
        let introPrompt = manager
            .combinePrompts(&activeCard.id, Vec::new(), promptFunctionType)
            .map_err(|error| error.to_string())?;
        let aiName = if activeCard.name.trim().is_empty() {
            "Operit".to_string()
        } else {
            activeCard.name.clone()
        };
        Ok(ProviderCharacterPromptContext {
            activeCard,
            introPrompt,
            aiName,
        })
    }

    /// Returns skill package descriptions visible to AI prompt composition.
    fn aiVisibleSkillPackages(&self) -> Result<Vec<ProviderPackageInfo>, String> {
        let hostManager = self.tool_handler.getContext();
        let packages =
            SkillRepository::getInstance(&hostManager, self.tool_handler.runtimeSupport())
                .getAiVisibleSkillPackages()
                .into_iter()
                .map(|(name, skill)| ProviderPackageInfo {
                    name,
                    description: skill.description,
                })
                .collect();
        Ok(packages)
    }

    /// Returns the model binding for a function.
    fn modelBindingForFunction(
        &self,
        rootDir: PathBuf,
        functionType: FunctionType,
    ) -> Result<ProviderFunctionModelBinding, String> {
        let binding = FunctionalConfigManager::new(rootDir)
            .getModelBindingForFunction(functionType)
            .map_err(|error| error.to_string())?;
        Ok(ProviderFunctionModelBinding {
            providerId: binding.providerId,
            modelId: binding.modelId,
        })
    }

    /// Returns the resolved model config for a provider/model pair.
    fn resolvedModelConfig(
        &self,
        rootDir: PathBuf,
        providerId: &str,
        modelId: &str,
    ) -> Result<ResolvedModelConfig, String> {
        ModelConfigManager::new(rootDir)
            .getResolvedModelConfig(providerId, modelId)
            .map_err(|error| error.to_string())
    }

    /// Returns the saved ChatGPT Codex session.
    fn loadCodexTokens(
        &self,
    ) -> Result<operit_providers::chat::llmprovider::CodexOAuth::CodexOAuthTokens, String> {
        crate::data::preferences::CodexAuthPreferences::CodexAuthPreferences::getInstance()
            .load()?
            .ok_or_else(|| "Codex authorization is required".to_string())
    }

    /// Persists a refreshed ChatGPT Codex session.
    fn saveCodexTokens(
        &self,
        tokens: operit_providers::chat::llmprovider::CodexOAuth::CodexOAuthTokens,
    ) -> Result<(), String> {
        crate::data::preferences::CodexAuthPreferences::CodexAuthPreferences::getInstance()
            .save(&tokens)
    }

    /// Returns a provider profile by id.
    fn providerProfile(
        &self,
        rootDir: PathBuf,
        providerId: &str,
    ) -> Result<ProviderProfile, String> {
        ModelConfigManager::new(rootDir)
            .getProviderProfile(providerId)
            .map_err(|error| error.to_string())
    }

    /// Returns whether a ToolPkg AI provider is registered.
    fn hasToolPkgAiProvider(&self, providerId: &str) -> bool {
        ToolPkgAiProviderRegistry::get(providerId).is_some()
    }

    /// Returns a ToolPkg AI provider registration.
    fn toolPkgAiProvider(&self, providerId: &str) -> Option<ProviderToolPkgAiProviderRegistration> {
        ToolPkgAiProviderRegistry::get(providerId).map(providerRegistrationToProvider)
    }

    /// Invokes a ToolPkg AI provider hook.
    fn runToolPkgAiProviderHook(
        &self,
        containerPackageName: &str,
        functionName: &str,
        functionSource: Option<&str>,
        event: &str,
        tag: Option<String>,
        sourceKey: Option<String>,
        eventPayload: Value,
        runtimeContextKey: Option<String>,
        executionKind: Option<String>,
        onIntermediateResult: Option<Arc<dyn Fn(String) + Send + Sync>>,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<Option<String>, String>> + Send>>
    {
        let package_manager = self.tool_handler.getOrCreatePackageManager();
        let manager = package_manager
            .lock()
            .expect("package manager mutex poisoned")
            .clone();
        manager.runToolPkgMainHook(
            containerPackageName,
            functionName,
            event,
            tag.as_deref(),
            sourceKey.as_deref(),
            functionSource,
            eventPayload,
            runtimeContextKey.as_deref(),
            executionKind.as_deref(),
            onIntermediateResult,
        )
    }

    /// Decodes a ToolPkg hook result.
    fn decodeToolPkgHookResult(&self, raw: Option<String>) -> Option<Value> {
        decodeToolPkgHookResult(raw)
    }

    /// Returns a provider timing snapshot.
    fn messageTimingNow(&self) -> ProviderMessageTiming {
        let timing = crate::core::chat::AIMessageManager::messageTimingNow();
        ProviderMessageTiming {
            startedAtMs: timing.startedAtMs,
        }
    }

    /// Writes a provider timing log entry.
    fn logMessageTiming(
        &self,
        stage: &str,
        startTimeMs: ProviderMessageTiming,
        details: Option<String>,
    ) {
        crate::core::chat::AIMessageManager::logMessageTiming(
            stage,
            crate::core::chat::AIMessageManager::MessageTiming {
                startedAtMs: startTimeMs.startedAtMs,
            },
            details,
        );
    }
}

/// Converts a runtime ToolPkg provider registration to the provider crate shape.
fn providerRegistrationToProvider(
    registration: ToolPkgAiProviderRegistration,
) -> ProviderToolPkgAiProviderRegistration {
    ProviderToolPkgAiProviderRegistration {
        containerPackageName: registration.containerPackageName,
        providerId: registration.providerId,
        displayName: registration.displayName,
        description: registration.description,
        listModelsFunctionName: registration.listModelsFunctionName,
        listModelsFunctionSource: registration.listModelsFunctionSource,
        sendMessageFunctionName: registration.sendMessageFunctionName,
        sendMessageFunctionSource: registration.sendMessageFunctionSource,
        testConnectionFunctionName: registration.testConnectionFunctionName,
        testConnectionFunctionSource: registration.testConnectionFunctionSource,
        calculateInputTokensFunctionName: registration.calculateInputTokensFunctionName,
        calculateInputTokensFunctionSource: registration.calculateInputTokensFunctionSource,
    }
}
