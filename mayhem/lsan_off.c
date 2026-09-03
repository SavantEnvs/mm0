/* Fleet policy: LeakSanitizer is disabled at BUILD time via this hook, never by baking
 * sanitizer option strings into the binary and never through runtime
 * __lsan_disable()/__lsan_enable() calls. Mayhem alone owns the sanitizer environment.
 *
 * mm0-c intentionally does not free its parsed state before exit, so LSan would report a
 * leak on essentially every input and drown the real defects. ASan itself stays on.
 */
int __lsan_is_turned_off(void) { return 1; }
