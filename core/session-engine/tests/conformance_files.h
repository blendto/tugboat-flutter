// Files under <repo>/conformance/ that are shared inputs, not fixtures. Used
// by the conformance runner and the unit tests that read them.
#ifndef TUGBOAT_SESSION_ENGINE_TESTS_CONFORMANCE_FILES_H
#define TUGBOAT_SESSION_ENGINE_TESTS_CONFORMANCE_FILES_H

namespace conformance {

// Shared Retry-After parser vectors (C++ engine and Dart sink).
constexpr char kRetryAfterVectorsFile[] = "retry_after_vectors.json";

}  // namespace conformance

#endif  // TUGBOAT_SESSION_ENGINE_TESTS_CONFORMANCE_FILES_H
