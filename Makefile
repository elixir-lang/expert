poncho_dirs = forge expert_credo engine expert

local_target :=
ifeq ($(OS),Windows_NT)
	local_target := $(local_target)windows
	ifeq ($(PROCESSOR_ARCHITECTURE),AMD64)
		local_target := $(local_target)_amd64
	endif
	ifeq ($(PROCESSOR_ARCHITECTURE),x86)
		local_target := $(local_target)_amd64
	endif
else
	UNAME_S := $(shell uname -s)
	ifeq ($(UNAME_S),Linux)
		local_target := $(local_target)linux
	endif
	ifeq ($(UNAME_S),Darwin)
		local_target := $(local_target)darwin
	endif
		UNAME_P := $(shell uname -p)
	ifeq ($(UNAME_P),x86_64)
		local_target := $(local_target)_amd64
	endif
	ifneq ($(filter %86,$(UNAME_P)),)
		local_target := $(local_target)_amd64
	endif
	ifneq ($(filter arm%,$(UNAME_P)),)
		local_target := $(local_target)_arm64
	endif
endif

compile.all: compile.poncho

dialyzer.all: compile.poncho dialyzer.poncho

test.all: test.poncho

dialyzer.plt.all: dialyzer.plt.poncho

env.test:
	export MIX_ENV=test

deps.poncho:
	$(foreach dir, $(poncho_dirs), cd apps/$(dir) && echo $(dir) && mix deps.get && cd ../..;)

clean.poncho:
	$(foreach dir, $(poncho_dirs), cd apps/$(dir) && echo $(dir) && mix clean && cd ../..;)

deps.compile.poncho: deps.poncho
	$(foreach dir, $(poncho_dirs), cd apps/$(dir) && mix deps.compile && cd ../..;)

compile.poncho: deps.poncho
	$(foreach dir, $(poncho_dirs), cd apps/$(dir) && mix deps.get && mix compile --warnings-as-errors && cd ../..;)

compile.protocols.poncho: deps.poncho
	$(foreach dir, $(poncho_dirs), cd apps/$(dir) && mix deps.get && mix compile.protocols --warnings-as-errors && cd ../..;)

test.poncho: deps.poncho
	$(foreach dir, $(poncho_dirs), cd apps/$(dir) && MIX_ENV=test mix test && cd ../..;)

format.check.poncho: env.test deps.poncho
	$(foreach dir, $(poncho_dirs), cd apps/$(dir) && mix format --check-formatted && cd ../..;)

credo.check.poncho: deps.poncho
	$(foreach dir, $(poncho_dirs), cd apps/$(dir) && mix credo && cd ../..;)

dialyzer.plt.poncho:
	$(foreach dir, $(poncho_dirs), cd apps/$(dir) && mix dialyzer --plt && cd ../..;)

dialyzer.poncho: compile.poncho compile.protocols.poncho
	$(foreach dir, $(poncho_dirs), cd apps/$(dir) && mix dialyzer && cd ../..;)

build.engine:
	cd apps/engine && mix deps.get && MIX_ENV=dev mix build

release: build.engine
	cd apps/expert &&\
		mix deps.get &&\
		EXPERT_RELEASE_MODE=burrito MIX_ENV=prod mix release --force --overwrite

release.local: build.engine
	cd apps/expert &&\
		mix deps.get &&\
		EXPERT_RELEASE_MODE=burrito BURRITO_TARGET=$(local_target) MIX_ENV=prod mix release --force --overwrite

