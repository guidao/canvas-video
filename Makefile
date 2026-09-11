EMACS ?= emacs
PKG_CONFIG ?= pkg-config
EMACS_INCLUDE ?= $(firstword $(foreach dir,/opt/homebrew/include /usr/local/include /usr/include,$(if $(wildcard $(dir)/emacs-module.h),$(dir))))
MODULE_SUFFIX := $(shell $(EMACS) --batch -Q --eval '(princ module-file-suffix)')
MPV_CFLAGS := $(shell $(PKG_CONFIG) --cflags mpv)
MPV_LIBS := $(shell $(PKG_CONFIG) --libs mpv)
CFLAGS ?= -O2 -g
WARNINGS = -std=c11 -Wall -Wextra -Werror -pthread
MODULE = canvas-video-module$(MODULE_SUFFIX)

ifeq ($(shell uname -s),Darwin)
SHARED = -dynamiclib
else
SHARED = -shared
endif

.PHONY: all check check-telega check-gui fixture clean
all: $(MODULE)

$(MODULE): src/player.c src/player.h src/module.c src/scale.c src/scale.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) -fPIC $(SHARED) -I"$(EMACS_INCLUDE)" $(MPV_CFLAGS) src/player.c src/module.c src/scale.c $(LDFLAGS) $(MPV_LIBS) -o $@

tests/scale-test: tests/scale-test.c src/scale.c src/scale.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) -Isrc src/scale.c tests/scale-test.c $(LDFLAGS) -o $@

tests/player-test: tests/player-test.c src/player.c src/player.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) -Isrc $(MPV_CFLAGS) src/player.c tests/player-test.c $(LDFLAGS) $(MPV_LIBS) -o $@

tests/fixture.mkv:
	ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=red:s=320x180:r=30:d=2' -f lavfi -i 'color=c=blue:s=320x180:r=30:d=2' -f lavfi -i 'sine=frequency=440:duration=4' -filter_complex '[0:v][1:v]concat=n=2:v=1:a=0[v]' -map '[v]' -map 2:a -c:v ffv1 -c:a pcm_s16le $@

fixture: tests/fixture.mkv

check: all tests/player-test tests/scale-test fixture
	./tests/player-test "$(CURDIR)/tests/fixture.mkv"
	./tests/scale-test
	$(EMACS) --batch -Q -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile canvas-video.el canvas-video-volume.el
	$(EMACS) --batch -Q --module-assertions -L . -l tests/canvas-video-build-test.el -l tests/canvas-video-test.el -l tests/canvas-video-volume-test.el -f ert-run-tests-batch-and-exit
	$(MAKE) check-telega

check-telega:
	$(EMACS) --batch -Q -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile canvas-video-telega.el
	$(EMACS) --batch -Q -L . -l tests/canvas-video-telega-test.el -f ert-run-tests-batch-and-exit

check-gui: all fixture
	$(EMACS) -Q --module-assertions --no-splash -L "$(CURDIR)" -l "$(CURDIR)/tests/gui-smoke.el"

clean:
	$(RM) canvas-video-module.dylib canvas-video-module.so canvas-video.elc canvas-video-volume.elc canvas-video-telega.elc tests/player-test tests/scale-test tests/fixture.mkv
