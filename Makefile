poncho_dirs = forge expert_credo engine expert

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

package:
	cd apps/expert && mix package
