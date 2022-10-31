# Considerations when using vWAN static routes and ExpressRoute

_Under construction..._

## Intro

This post aims to review some scenarios you may encounter when leveraging static routes in Virtual WAN with inter-region vHubs and ExpressRoute cross-connected circuits.

### Network topology reference

![](./media/base-network-topology.png)

## Background

### Option 3: Split ranges

**Virtual Hub** Routes

```Bash
vHUB: hub1
Effective route table: defaultroutetable
AddressPrefixes    NextHopType                 AsPath
-----------------  --------------------------  -----------------
10.2.0.0/17        Virtual Network Connection
10.2.128.0/17      Virtual Network Connection
10.4.0.0/16        Virtual Network Connection
10.1.0.0/24        Virtual Network Connection
10.2.0.0/24        Virtual Network Connection
10.100.0.0/16      VPN_S2S_Gateway             65510
10.3.0.0/24        ExpressRouteGateway         12076-12076
10.4.0.0/24        ExpressRouteGateway         12076-12076
192.168.2.0/24     ExpressRouteGateway         12076-12076
10.200.0.0/16      Remote Hub                  65520-65520-65509

vHUB: hub2
Effective route table: defaultroutetable
AddressPrefixes    NextHopType                 AsPath
-----------------  --------------------------  -----------------
10.2.0.0/16        Virtual Network Connection
10.4.0.0/16        Virtual Network Connection
10.200.0.0/16      VPN_S2S_Gateway             65509
10.2.0.0/24        ExpressRouteGateway         12076-12076
10.1.0.0/24        ExpressRouteGateway         12076-12076
10.4.0.0/24        Virtual Network Connection
10.3.0.0/24        Virtual Network Connection
192.168.1.0/24     ExpressRouteGateway         12076-12076
10.100.0.0/16      Remote Hub                  65520-65520-65510
```

