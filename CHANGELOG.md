# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Provider errors are reported, not swallowed**: the streaming error
  callback took one argument where llm.el passes two, so every API failure
  raised `wrong-number-of-arguments` and the real message was never shown.
  The second argument is a message string rather than an error object, so it
  is formatted directly: `error-message-string` would signal on it.
- **`g` in the summary buffer regenerates**: it cleared the cache and printed
  "Please regenerate from the mu4e message view". The message and the summary
  type are now kept in the buffer, so a summary can rerun itself.

### Added

- **`mu4e-llm-operation-models`**: a model and reasoning level per operation,
  so summarising and drafting need not share one model. Keyed by operation
  type (`summary`, `executive-summary`, `translate`, `draft`, `compose`,
  `refine`), with `:model` and `:reasoning` both optional:

  ```elisp
  (setq mu4e-llm-operation-models
        '((summary . (:model "gpt-6-luna"  :reasoning "low"))
          (draft   . (:model "gpt-6.1-sol" :reasoning "medium"))))
  ```

  Defaults to nil and nothing inherits, so an absent operation behaves
  exactly as before. The provider is copied before its model is replaced,
  because the same object is shared with the user's other AI tools.

  The reasoning level is sent as a `reasoning_effort` request parameter, so
  its accepted values are the provider's. llm.el has a `:reasoning` argument
  of its own, but the Open AI provider does not read it: only the Claude,
  Vertex and Ollama providers do.

- **`mu4e-llm-parent-keymap` and `mu4e-llm-parent-keymap-suffix`**: the
  shared-prefix binding used to be derived by matching the prefix against
  `C-c a`, which tied the two together and refused any other prefix shape. A
  single unmodified key now works, which suits mu4e because its buffers are
  modal.

### Changed

- The suffix inside the parent keymap is no longer derived from
  `mu4e-llm-keymap-prefix`. It defaults to `e`, matching the previous
  default. Set `mu4e-llm-parent-keymap-suffix` if you had changed the prefix.
- `mu4e-llm-help` names the prefix actually in use instead of a hardcoded one.

## [0.1.0] - 2025-01-01

### Added

- **Thread Summarization**: Generate detailed or executive summaries of email threads
  - `mu4e-llm-summarize` - Full thread summary with key points
  - `mu4e-llm-summarize-executive` - Brief 2-3 sentence summary
  - Summary caching with configurable TTL

- **Smart Reply Drafting**: AI-powered email reply generation
  - `mu4e-llm-draft-reply` - Context-aware reply drafts
  - `mu4e-llm-draft-compose` - Compose new emails with AI
  - Iterative refinement: shorten, make polite, custom instructions
  - org-msg integration for styled HTML emails

- **Translation**: Translate messages and threads
  - `mu4e-llm-translate-message` - Translate current message
  - `mu4e-llm-translate-thread` - Translate entire thread
  - `mu4e-llm-translate-region` - Translate selected text
  - Configurable target languages

- **Provider Agnostic**: Works with any llm.el provider
  - OpenAI, Claude, Gemini, Ollama support
  - Streaming responses with progress indicators
  - Configurable temperature and max tokens

- **Customizable Keybindings**:
  - Default prefix: `C-c a e`
  - Integrates with `ai-commands-prefix-map` when available
  - Configurable via `mu4e-llm-keymap-prefix`

### Configuration Options

- `mu4e-llm-provider` - LLM provider instance
- `mu4e-llm-temperature` - Response creativity (0.0-1.0)
- `mu4e-llm-max-tokens` - Maximum response length
- `mu4e-llm-max-thread-messages` - Thread extraction limit
- `mu4e-llm-cache-summaries` - Enable summary caching
- `mu4e-llm-draft-persona` - Default reply style
- `mu4e-llm-languages` - Available translation languages
