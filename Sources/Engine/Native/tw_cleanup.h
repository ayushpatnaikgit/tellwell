// TellWell's cleanup engine: S1-mini (Qwen3-0.6B fine-tune) through llama.cpp, shared by the Mac and Android apps.
//
// - Keeps the KV cache of the previous request and reuses its longest common token prefix, so the fixed
//   instructions are read once (vocabulary or screen-word sections only cost their own tokens).
// - Greedy decoding with optional copy-ahead drafts: up to draft_k tokens copied from earlier in the prompt are
//   checked in the same forward pass; the text equals plain greedy decoding.
// - Nothing here logs or stores the text it processes.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Loads the model. n_gpu_layers: 99 = all on the GPU (Metal on the Mac). Returns 0 on success.
int tw_cleanup_load(const char *model_path, int n_gpu_layers, int threads, int n_ctx);

// Runs one chat prompt (already rendered with the chat template). Returns the generated text (UTF-8), which the
// caller frees with tw_cleanup_free, or NULL on failure.
char *tw_cleanup_complete(const char *prompt, int max_tokens, int draft_k);

void tw_cleanup_free(char *text);
// Frees the model. Must run before the process exits: llama.cpp's Metal backend aborts at exit otherwise.
void tw_cleanup_unload(void);
int tw_cleanup_is_loaded(void);

#ifdef __cplusplus
}
#endif
