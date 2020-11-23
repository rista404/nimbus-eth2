import std/options,
  chronicles,
  json_rpc/[rpcserver, jsonmarshal],
  eth/p2p/discoveryv5/enr,
  nimcrypto/utils as ncrutils,
  ../beacon_node_common, ../eth2_network, ../sync_manager,
  ../peer_pool, ../version,
  ../spec/[datatypes, digest, presets],
  ../spec/eth2_apis/callsigs_types

logScope: topics = "nodeapi"

type
  RpcServer = RpcHttpServer

template unimplemented() =
  raise (ref CatchableError)(msg: "Unimplemented")

type
  RpcPeer* = object
    peer_id*: string
    enr*: string
    last_seen_p2p_address*: string
    state*: string
    direction*: string
    agent*: string
    proto*: string

  RpcPeerCount* = object
    disconnected*: int
    connecting*: int
    connected*: int
    disconnecting*: int

proc validatePeerState(state: Option[seq[string]]): Option[set[ConnectionState]] =
  var res: set[ConnectionState]
  if state.isSome():
    let states = state.get()
    for item in states:
      case item
      of "disconnected":
        if ConnectionState.Disconnected notin res:
          res.incl(ConnectionState.Disconnected)
        else:
          # `state` values should be unique
          return none(set[ConnectionState])
      of "connecting":
        if ConnectionState.Disconnected notin res:
          res.incl(ConnectionState.Connecting)
        else:
          # `state` values should be unique
          return none(set[ConnectionState])
      of "connected":
        if ConnectionState.Connected notin res:
          res.incl(ConnectionState.Connected)
        else:
          # `state` values should be unique
          return none(set[ConnectionState])
      of "disconnecting":
        if ConnectionState.Disconnecting notin res:
          res.incl(ConnectionState.Disconnecting)
        else:
          # `state` values should be unique
          return none(set[ConnectionState])
      else:
        # Found incorrect `state` string value
        return none(set[ConnectionState])

  if res == {}:
    res = {ConnectionState.Connecting, ConnectionState.Connected,
           ConnectionState.Disconnecting, ConnectionState.Disconnected}
  some(res)

proc validateDirection(direction: Option[seq[string]]): Option[set[PeerType]] =
  var res: set[PeerType]
  if direction.isSome():
    let directions = direction.get()
    for item in directions:
      case item
      of "inbound":
        if PeerType.Incoming notin res:
          res.incl(PeerType.Incoming)
        else:
          # `direction` values should be unique
          return none(set[PeerType])
      of "outbound":
        if PeerType.Outgoing notin res:
          res.incl(PeerType.Outgoing)
        else:
          # `direction` values should be unique
          return none(set[PeerType])
      else:
        # Found incorrect `direction` string value
        return none(set[PeerType])

  if res == {}:
    res = {PeerType.Incoming, PeerType.Outgoing}
  some(res)

proc toString(state: ConnectionState): string =
  case state
  of ConnectionState.Disconnected:
    "disconnected"
  of ConnectionState.Connecting:
    "connecting"
  of ConnectionState.Connected:
    "connected"
  of ConnectionState.Disconnecting:
    "disconnecting"
  else:
    ""

proc toString(direction: PeerType): string =
  case direction:
  of PeerType.Incoming:
    "inbound"
  of PeerType.Outgoing:
    "outbound"

proc getLastSeenAddress(info: PeerInfo): string =
  # TODO (cheatfate): We need to provide filter here, which will be able to
  # filter such multiaddresses like `/ip4/0.0.0.0` or local addresses or
  # addresses with peer ids.
  if len(info.addrs) > 0:
    $info.addrs[len(info.addrs) - 1]
  else:
    ""

proc installNodeApiHandlers*(rpcServer: RpcServer, node: BeaconNode) =
  rpcServer.rpc("get_v1_node_identity") do () -> NodeIdentityTuple:
    return (
      peer_id: node.network.peerId(),
      enr: node.network.enrRecord(),
      # TODO rest of fields
      p2p_addresses: newSeq[MultiAddress](0),
      discovery_addresses: newSeq[MultiAddress](0),
      metadata: (node.network.metadata.seq_number,
                 "0x" & ncrutils.toHex(node.network.metadata.attnets.bytes))
    )

  rpcServer.rpc("get_v1_node_peers") do (state: Option[seq[string]],
                                direction: Option[seq[string]]) -> seq[RpcPeer]:
    var res = newSeq[RpcPeer]()
    let rstates = validatePeerState(state)
    if rstates.isNone():
      raise newException(CatchableError, "Incorrect state parameter")
    let rdirs = validateDirection(direction)
    if rdirs.isNone():
      raise newException(CatchableError, "Incorrect direction parameter")
    let states = rstates.get()
    let dirs = rdirs.get()
    for item in node.network.peers.values():
      if (item.connectionState in states) and (item.direction in dirs):
        let rpeer = RpcPeer(
          peer_id: $item.info.peerId,
          enr: if item.enr.isSome(): item.enr.get().toUri() else: "",
          last_seen_p2p_address: item.info.getLastSeenAddress(),
          state: item.connectionState.toString(),
          direction: item.direction.toString(),
          agent: item.info.agentVersion, # Fields `agent` and `proto` are not
          proto: item.info.protoVersion  # part of specification.
        )
        res.add(rpeer)
    return res

  rpcServer.rpc("get_v1_node_peer_count") do () -> RpcPeerCount:
    var res: RpcPeerCount
    for item in node.network.peers.values():
      case item.connectionState
      of Connecting:
        inc(res.connecting)
      of Connected:
        inc(res.connected)
      of Disconnecting:
        inc(res.disconnecting)
      of Disconnected:
        inc(res.disconnected)
      of ConnectionState.None:
        discard
    return res

  rpcServer.rpc("get_v1_node_peers_peerId") do (peer_id: string) -> RpcPeer:
    let pres = PeerID.init(peer_id)
    if pres.isErr():
      raise newException(CatchableError,
                         "The peer ID supplied could not be parsed")
    let pid = pres.get()
    let peer = node.network.peers.getOrDefault(pid)
    if isNil(peer):
      raise newException(CatchableError, "Peer not found")

    return RpcPeer(
      peer_id: $peer.info.peerId,
      enr: if peer.enr.isSome(): peer.enr.get().toUri() else: "",
      last_seen_p2p_address: peer.info.getLastSeenAddress(),
      state: peer.connectionState.toString(),
      direction: peer.direction.toString(),
      agent: peer.info.agentVersion, # Fields `agent` and `proto` are not part
      proto: peer.info.protoVersion  # of specification
    )

  rpcServer.rpc("get_v1_node_version") do () -> JsonNode:
    return %{"version": "Nimbus/" & fullVersionStr}

  rpcServer.rpc("get_v1_node_syncing") do () -> SyncInfo:
    return node.syncManager.getInfo()

  rpcServer.rpc("get_v1_node_health") do () -> JsonNode:
    # TODO: There currently no way to situation when we node has issues, so
    # its impossible to return HTTP ERROR 503 according to specification.
    if node.syncManager.inProgress:
      # We need to return HTTP ERROR 206 according to specification
      return %{"health": 206}
    else:
      return %{"health": 200}