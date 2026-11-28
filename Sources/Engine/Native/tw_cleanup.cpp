#include "tw_cleanup.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "llama.h"

namespace {

struct State {
    llama_model *model = nullptr;
    llama_context *ctx = nullptr;
    const llama_vocab *vocab = nullptr;
    int n_ctx = 0;
    std::vector<llama_token> cached;  // exactly the tokens in the KV cache (sequence 0)
};

State g;
std::mutex g_mu;

std::vector<llama_token> tokenize(const std::string &text) {
    int n = -llama_tokenize(g.vocab, text.c_str(), (int32_t) text.size(), nullptr, 0, false, true);
    std::vector<llama_token> tokens(std::max(n, 0));
    if (n <= 0 || llama_tokenize(g.vocab, text.c_str(), (int32_t) text.size(), tokens.data(), n, false, true) < 0) {
        tokens.clear();
    }
    return tokens;
}

llama_token argmax(const float *logits, int n) {
    int best = 0;
    for (int i = 1; i < n; i++) {
        if (logits[i] > logits[best]) best = i;
    }
    return best;
}

// Most recent earlier occurrence of the last n tokens (n = 4 down to 1): propose up to k tokens that followed it.
std::vector<llama_token> lookup(const std::vector<llama_token> &ctx, int k) {
    for (int n = 4; n >= 1; n--) {
        if ((int) ctx.size() <= n) continue;
        const size_t tail = ctx.size() - n;
        for (ptrdiff_t i = (ptrdiff_t) tail - 1; i >= 0; i--) {
            if (std::equal(ctx.begin() + i, ctx.begin() + i + n, ctx.begin() + tail)) {
                const size_t from = i + n, to = std::min(ctx.size(), from + (size_t) k);
                return std::vector<llama_token>(ctx.begin() + from, ctx.begin() + to);
            }
        }
    }
    return {};
}

// Feed tokens at positions pos.. with logits for every one; returns false on failure.
bool feed(llama_batch &batch, const llama_token *tokens, int n, int pos, bool all_logits) {
    batch.n_tokens = 0;
    for (int i = 0; i < n; i++) {
        batch.token[i] = tokens[i];
        batch.pos[i] = pos + i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i] = all_logits || i == n - 1;
    }
    batch.n_tokens = n;
    return llama_decode(g.ctx, batch) == 0;
}

void release() {
    if (g.ctx) llama_free(g.ctx);
    if (g.model) llama_model_free(g.model);
    g = State();
}

}  // namespace

extern "C" int tw_cleanup_load(const char *model_path, int n_gpu_layers, int threads, int n_ctx) {
    std::lock_guard<std::mutex> lock(g_mu);
    release();
    static bool backend = false;
    if (!backend) {
        // llama.cpp logs model details to stderr by default: keep the app's output quiet (it never logs text anyway).
        llama_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
        llama_backend_init();
        backend = true;
    }
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = n_gpu_layers;
    g.model = llama_model_load_from_file(model_path, mp);
    if (!g.model) return 1;
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = n_ctx;
    cp.n_batch = 512;
    cp.n_ubatch = 512;
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    // 8-bit KV cache (needs Flash Attention for the V cache): half the memory of f16 (S1-mini at 4096 tokens:
    // ~448 -> ~224 MB) and half the cache read per token. Same score on the 95 cleanup cases; 4-bit broke it.
    cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
    cp.type_k = GGML_TYPE_Q8_0;
    cp.type_v = GGML_TYPE_Q8_0;
    g.ctx = llama_init_from_model(g.model, cp);
    if (!g.ctx) {
        llama_model_free(g.model);
        g = State();
        return 2;
    }
    g.vocab = llama_model_get_vocab(g.model);
    g.n_ctx = n_ctx;
    return 0;
}

extern "C" char *tw_cleanup_complete(const char *prompt, int max_tokens, int draft_k) {
    std::lock_guard<std::mutex> lock(g_mu);
    if (!g.ctx || !prompt) return nullptr;
    std::vector<llama_token> ids = tokenize(prompt);
    // Fit the output budget into the context window; fail only if the prompt itself doesn't fit.
    const int room = g.n_ctx - (int) ids.size() - std::max(0, (int) draft_k) - 1;
    if (ids.empty() || room < 1) return nullptr;
    max_tokens = std::min(max_tokens, room);
    llama_memory_t mem = llama_get_memory(g.ctx);

    // Reuse the longest common prefix of the previous request (keep at least one token to feed).
    size_t n = 0;
    while (n < g.cached.size() && n + 1 < ids.size() && g.cached[n] == ids[n]) n++;
    llama_memory_seq_rm(mem, 0, (llama_pos) n, -1);
    g.cached.assign(ids.begin(), ids.begin() + n);

    const int n_batch = 512;
    llama_batch batch = llama_batch_init(std::max(n_batch, 1 + std::max(0, draft_k)), 0, 1);
    for (size_t i = n; i < ids.size(); i += n_batch) {
        const int m = (int) std::min(ids.size() - i, (size_t) n_batch);
        if (!feed(batch, ids.data() + i, m, (int) i, false)) {
            llama_batch_free(batch);
            llama_memory_seq_rm(mem, 0, 0, -1);
            g.cached.clear();
            return nullptr;
        }
        g.cached.insert(g.cached.end(), ids.begin() + i, ids.begin() + i + m);
    }

    const int n_vocab = llama_vocab_n_tokens(g.vocab);
    std::vector<llama_token> ctx_toks = ids;
    std::string out;
    char buf[256];
    int produced = 0;
    bool done = false;
    auto emit = [&](llama_token t) {
        if (llama_vocab_is_eog(g.vocab, t) || produced >= max_tokens) {
            done = true;
            return;
        }
        const int len = llama_token_to_piece(g.vocab, t, buf, sizeof(buf), 0, false);
        if (len > 0) out.append(buf, len);
        produced++;
        ctx_toks.push_back(t);
    };

    llama_token y = argmax(llama_get_logits_ith(g.ctx, -1), n_vocab);
    emit(y);
    while (!done) {
        // y is not in the KV cache yet: feed it together with the draft.
        std::vector<llama_token> inp{y};
        if (draft_k > 0) {
            std::vector<llama_token> d = lookup(ctx_toks, draft_k);
            inp.insert(inp.end(), d.begin(), d.end());
        }
        const int pos = (int) g.cached.size();
        if (!feed(batch, inp.data(), (int) inp.size(), pos, true)) break;
        g.cached.insert(g.cached.end(), inp.begin(), inp.end());
        size_t a = 0;
        llama_token next;
        while (true) {
            next = argmax(llama_get_logits_ith(g.ctx, (int) a), n_vocab);
            if (a + 1 < inp.size() && next == inp[a + 1]) {
                emit(next);
                a++;
                if (done) break;
            } else {
                break;
            }
        }
        // Keep y and the accepted drafts; drop the rejected ones from the cache.
        const size_t keep = pos + 1 + a;
        llama_memory_seq_rm(mem, 0, (llama_pos) keep, -1);
        g.cached.resize(keep);
        if (done) break;
        emit(next);
        y = next;
    }
    llama_batch_free(batch);
    char *result = (char *) std::malloc(out.size() + 1);
    if (result) std::memcpy(result, out.c_str(), out.size() + 1);
    return result;
}

extern "C" void tw_cleanup_free(char *text) { std::free(text); }

extern "C" void tw_cleanup_unload(void) {
    std::lock_guard<std::mutex> lock(g_mu);
    release();
}

extern "C" int tw_cleanup_is_loaded(void) {
    std::lock_guard<std::mutex> lock(g_mu);
    return g.ctx != nullptr;
}
