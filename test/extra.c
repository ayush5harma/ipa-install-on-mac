// A --dylib fixture for test/e2e.sh: its constructor writes one line to the
// probe's log, so a check can see an extra library was built for Mac
// Catalyst, linked, signed and loaded.
#include <stdio.h>
#include <stdlib.h>

__attribute__((constructor)) static void extra_loaded(void) {
  const char *home = getenv("HOME");   // the sandbox container's Data
  if (!home) return;
  char path[1024];
  snprintf(path, sizeof path, "%s/Documents/probe.log", home);
  FILE *f = fopen(path, "a");
  if (!f) return;
  fputs("extra dylib loaded\n", f);
  fclose(f);
}
