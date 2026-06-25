# fastroute.tcl — Per-design GRT layer and adjustment settings.
# Sourced via PRE_GLOBAL_ROUTE_TCL before global_route is invoked.
#
# Limit signal routing to met4 and below: met5 in sky130hd is consumed by
# horizontal PDN straps, causing GRT-0232 congestion near SRAM macro clusters.
# met4 has 17% average utilization — more than enough routing headroom.

set_global_routing_layer_adjustment met1-met4 0.2

set_routing_layers -clock $::env(MIN_CLK_ROUTING_LAYER)-met4
set_routing_layers -signal $::env(MIN_ROUTING_LAYER)-met4
