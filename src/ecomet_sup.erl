%%----------------------------------------------------------------
%% Copyright (c) 2020 Faceplate
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%----------------------------------------------------------------

-module(ecomet_sup).

-include("ecomet.hrl").

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

-define(DEFAULT_MAX_RESTARTS,10).
-define(DEFAULT_MAX_PERIOD,1000).
-define(DEFAULT_SCAN_CYCLE,1000).
-define(DEFAULT_STOP_TIMEOUT,600000). % 10 min.

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
  SchemaSrv=#{
    id=>ecomet_schema,
    start=>{ecomet_schema,start_link,[]},
    restart=>permanent,
    shutdown=>?ENV(stop_timeout, ?DEFAULT_STOP_TIMEOUT),
    type=>worker,
    modules=>[ecomet_schema]
  },

  Supervisor=#{
    strategy=>one_for_one,
    intensity=>?ENV(segemnt_max_restarts, ?DEFAULT_MAX_RESTARTS),
    period=>?ENV(segemnt_max_period, ?DEFAULT_MAX_PERIOD)
  },

  {ok, {Supervisor, [
    SchemaSrv
  ]}}.

