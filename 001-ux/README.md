# Franz User Experience

Status: **ready**

## Purpose and Initial Scope

Franz is the control plane for an async fleet. Users declare their intended async resources and Franz keeps that intended state, applies fleet-wide governance, and receives signals about its realization. Franz does not directly connect to or change Kafka clusters; agents perform real-world operations.

This initial UX scope covers:

- Kafka Cluster registration and context-label maintenance.
- Agent registration — the programs that connect to the fleet API and act on fleet data.
- Governance — policies that read fleet indicators and act on the resources they match.
- Creating and maintaining an Async Channel of type `kafka-topic`.
- Configuring the Kafka Topic generated for that channel.
- Client registration and per-channel access policies granting Read and Write.
- Channel lifecycle controls and control-plane status.
- Scope-based authorization.

It deliberately does not define multi-topic channels, migrations, cluster upgrades, or capacity management.

## Product Model

An **Async Channel** is the customer-facing boundary of asynchronous communication. In this initial scope, its only supported type is `kafka-topic`.

Creating a `kafka-topic` channel causes Franz to generate one linked **Kafka Topic** entity. The generated Kafka Topic represents the desired Kafka resource and owns Kafka-specific configuration. Customers do not create the Kafka Topic as an independent primary resource.

```text
Async Channel
  ├─ identity and lifecycle
  ├─ type: kafka-topic
  ├─ one placement context
  └─ generated Kafka Topic
       ├─ Franz-generated Kafka topic name
       └─ Kafka-specific configuration
```

Franz generates the Kafka topic name from the channel and topic information. The exact naming algorithm is outside this UX scope.

## Personas and Authorization

Franz authorizes actions through scopes, rather than a fixed set of product roles. Policies also restrict actions to an allowed list or pattern of resources, following the general model of IAM policies.

Examples of scopes:

- `async-channel:create`, `async-channel:read`, `async-channel:update`, `async-channel:pause`, `async-channel:delete`
- `kafka-cluster:create`, `kafka-cluster:read`, `kafka-cluster:update`, `kafka-cluster:delete`
- `agent:create`, `agent:read`, `agent:update`, `agent:delete`
- `policy:create`, `policy:read`, `policy:update`, `policy:delete`
- `client:create`, `client:read`, `client:update`, `client:delete` (the channel access policy is edited through `async-channel:update`)

Governance is administered by an **Async Admin** persona holding the `policy:*` scopes. The exact policy format and resource-pattern syntax are not defined here.

## Context and Placement

A **context** describes where an Async Channel should live in the fleet. Context is represented by labels; labels are the source of truth.

A Kafka Cluster declares its context using labels such as:

```text
org.com/env=prod
org.com/country=br
org.com/shard=s8
```

An Async Channel declares one context through matching labels. The user interface may show a readable summary, such as `br-prod-s8`, but must preserve the underlying label selector as the authoritative representation.

The actual placement depends on cluster availability in that context and fleet-wide governance. Advanced placement behavior—including multiple contexts, desired topic quantity, weights, taints, tolerations, and validation rules—is deferred.

## Kafka Cluster Experience

### Register a Kafka Cluster

The cluster-registration experience records control-plane intent only. It collects:

- Cluster identity.
- Bootstrap URL.
- Context labels.
- Optionally, the Cluster Provider agent that deploys and maintains this cluster.

Registration does not validate connectivity, discover brokers, configure TLS or authentication, install an agent, or interact with the Kafka cluster.

### Maintain a Kafka Cluster

Users can inspect a registered cluster and edit its labels/context. The experience shows the cluster's declared intent and available control-plane signals.

Cluster drains, upgrades, broker capacity, real-world health, and direct operational actions are outside this first scope.

## Agent Experience

An **agent** is a program registered with Franz that connects to the fleet API over gRPC, pulls the work that matches its context, and reports results. Franz never calls an agent and never acts on infrastructure itself; the agent reads declared state and does the real-world work.

Every agent is registered with:

- An identity.
- A **type**, used only to filter and organise agents in the console.
- A **fleet API endpoint** and protocol (gRPC).
- A **context selector** — a label expression (`=` and `IN (…)`) naming the slice of the fleet the agent is responsible for. Franz only hands the agent work that matches it. An empty selector means the whole fleet.

### Agent Types

| Type | Responsibility |
|---|---|
| **Cluster Provider** | Deploys and maintains the substrate that hosts a fleet resource — Kafka clusters, RabbitMQ, and similar. `br-prod-msk`, `br-prod-strimzi`, `local-docker` are Cluster Provider agents. |
| **Resource Provider** | Realises the individual resources on a substrate — Kafka topics, RabbitMQ queues, SQS queues. Gregor Samsa is a Resource Provider for Kafka topics. |
| **Telemetry Agent** | Publishes indicator data to Franz following the telemetry protocol. Governance policies read these indicators. |
| **Custom** | Any other program that reads from or acts on fleet data through the API. |

The type does not change how the agent connects or authenticates. It is an organisational filter only.

Deployment specifics for a Cluster Provider — a Strimzi `Kafka` resource, an MSK cluster ARN, a Docker stack — are configuration the agent reads from the fleet, not fields Franz collects on this screen. The authoritative schema belongs to the domain specification.

### Register an Agent

The user names the agent, chooses its type, gives the fleet API endpoint, and writes the context selector. A Telemetry Agent additionally sees a note describing the telemetry protocol it must follow to publish indicator samples.

### Kafka Cluster and Cluster Provider

A Kafka Cluster may optionally be linked to one **Cluster Provider** agent. A cluster without one is fully usable: Franz still records it and topics are still reconciled against it. The absent link only means no agent is registered to manage that cluster's substrate, which is the correct representation for clusters provisioned and operated outside Franz. One Cluster Provider agent can serve many clusters within its context selector.

## Governance Experience

Governance lets the Async Admin register **policies** that watch the fleet and act on it automatically.

A policy has four parts and a weight:

| Part | Meaning |
|---|---|
| **Indicator** | The value the policy watches — for example `replica-size`, `avg-replica-per-broker`, `retention-not-used`. Indicators are published by Telemetry Agents over the telemetry protocol. |
| **Matcher** | The resources the policy applies to: an **entity** (Kafka Topic, Kafka Cluster, Async Channel) and a **label selector** (`org.com/env=prod, org.com/country IN (br, mx)`). An empty selector means every resource of that entity. |
| **Limit** | The comparison that triggers the policy: less than, less than or equal, equal, not equal, greater than or equal, greater than — against a value. |
| **Actions** | What to run against every matched resource when the limit is crossed: `add_label(key, value)`, `remove_label(key)`, `set_status(status)`, `update_field(field, value)`, `increase_field_by(field, amount)`, `decrease_field_by(field, amount)`. |
| **Weight** | Relative importance. When several policies act on the same resource, weight decides which one wins. |

Actions change Franz's declared state only. The resulting change is realised by the normal reconciliation path — the same as any user edit. Franz never touches the real infrastructure directly.

### Governance screens

Governance is a navigation group with two screens:

- **Policies** lists every registered policy, each showing its indicator, matcher, limit, actions, weight, and enabled/disabled status.
- **Indicators** shows a summary of the available indicators — how many, how many are healthy versus stale, and recent indicator activity — above the full indicator list.

### Register a Policy

The user picks the entity, writes the label selector, chooses the indicator, sets the limit, and adds one or more actions, then sets a weight. A **dry run** previews which resources currently match and which would trigger on the latest indicator samples, without saving anything.

### Indicators

Indicators have their own list and detail views. The detail view shows the unit, the source Telemetry Agents, the sample interval and staleness threshold, recent samples per resource, and the policies that read the indicator. A stale indicator — no sample within its threshold — is shown as such, and policies reading it do not act until fresh data arrives.

## Async Channel Experience

### Create an Async Channel

The creation flow collects the channel identity, one label-based context, and an initial **access policy** (see below). The only available type is `kafka-topic`. After creation, Franz generates the linked Kafka Topic entity and its Kafka topic name.

### Channel access policy

Every channel carries **one access policy document**, in the style of an S3 bucket policy. It is a list of statements; each statement has an **effect** (`Allow` or `Deny`), a **principal** — a client ORN, a label selector (`=` and `IN (…)`), or both — and one or more permissions (`Read`, `Write`). `*` is a wildcard in the ORN and in label values.

Evaluation for a `(client, action)` is: among statements whose principal matches the client and whose permissions include the action, an explicit `Deny` wins; otherwise an explicit `Allow` grants; otherwise no access. Franz is **zero trust** — a client that matches no `Allow` has nothing. This lets a broad `Allow` (`…client:xpto-*`) coexist with a narrow `Deny` (`…client:xpto-blah`).

The client itself carries no role, so there is nothing to intersect — the policy is the sole source of permission.

The channel detail screen shows the statement list, the rendered policy document, and a derived **Clients with access** table listing the registered clients that currently match and the permission each one gets. The policy is edited on the channel (create form and detail), not on the client.

### Configure the Generated Kafka Topic

Kafka-specific configuration belongs to the generated Kafka Topic, not to the Async Channel itself. The channel experience exposes this linked resource so users can declare settings such as:

- Kafka partitions.
- Retention.
- Replication factor.
- Additional Kafka topic configuration.

Governance policies may change these declarations after the fact — for example increasing partitions when a size indicator crosses a limit. Such changes appear in the channel's status/signal history attributed to the policy that made them.

### Maintain an Async Channel

The channel detail experience shows:

- Channel identity, type, and label-based context.
- The generated Kafka Topic and generated Kafka topic name.
- Declared Kafka-specific configuration.
- Desired placement and available control-plane status/signals.
- The **load distribution** across the generated topics — the percentage of channel traffic written to each topic.
- A per-topic **consumption** control. Disabling a topic drains it: producers stop writing to it and its traffic share drops to 0%, while the topic and its data are retained.
- The **access policy** and the clients that currently have access.
- Lifecycle controls.

## Client Experience

A **client** is a fleet-wide identity that reads from or writes to Async Channels through the Franz SDK. A client has:

- A **name**, globally unique, which is also its ORN (`orn:acme-platform:client:<name>`) and the prefix of its default consumer groups.
- **Labels** — at least `org.com/owner`. Labels are what channel access policies match against.

A client carries **no Read/Write role**. Every permission comes from the access policy of the channel it connects to.

### Consumer groups

Consumer groups are **not registered** in Franz. When a client subscribes to a channel it uses the group `<client-name>.<topic>` by default, or a custom group name it passes to the SDK. Telemetry Agents report the groups they observe and link each one to the client and owner behind it; the client detail screen shows this observed list read-only.

### Client screens

- **Clients** list — name, owner, observed consumer groups, and a summary of channel access.
- **Register Client** — name and labels only.
- **Client detail** — identity and labels, a derived **Channel access** table (every channel whose policy matches this client, and the permission granted), and the observed consumer groups.

### SDK

The SDK is initialised with the channel ORN and the client ORN. Franz evaluates the channel's access policy against the client before allowing publish or subscribe. Client credentials and connection testing are outside this scope.

## Lifecycle and Control-Plane Status

| State | Meaning |
|---|---|
| **Active** | Franz automatically maintains the declared Async Channel intent. |
| **Paused** | The channel remains recorded, but Franz stops automatic management. |
| **Deleted** | The Franz entity is soft-deleted; agents perform deletion of the corresponding real-world resources. |

The interface must distinguish declared intent, signals received by the control plane, and the progress of real-world actions performed by agents.

## Information Architecture and Wireframe Plan

The navigation is **Home**, plus three groups: **Async Channels** holding **Channels** and **Clients**, **Governance** holding **Indicators** and **Policies**, and **Kafka** holding **Clusters** and **Agents**.

The first wireframe set should cover:

1. **Kafka Cluster list**: registered clusters, context-label summary, cluster provider, and control-plane status.
2. **Register Kafka Cluster**: identity, bootstrap URL, optional Cluster Provider selection, and context-label editor.
3. **Agent list**: registered agents, type, fleet API endpoint, and context selector.
4. **Register Agent**: identity, type, fleet API endpoint, and context selector.
5. **Policies**: the list of registered policies with indicator, matcher, limit, actions, and weight.
6. **Register Policy**: entity, selector, indicator, limit, actions, weight, and a dry-run preview.
7. **Policy detail**: definition, currently-matched resources, and action history.
8. **Indicator list** and **Indicator detail**: unit, source agents, samples, and the policies that read each indicator.
9. **Async Channel list**: channel identity, type, context, lifecycle, and summarized status.
10. **Create Async Channel**: channel identity, `kafka-topic` type, label-based context, and the initial access policy.
11. **Async Channel detail**: lifecycle controls, generated Kafka Topic, Kafka configuration, desired placement, load distribution, access policy, clients with access, and received status/signal history.
12. **Client list**: name, owner, observed consumer groups, and channel-access summary.
13. **Register Client**: name and labels.
14. **Client detail**: identity, labels, derived channel access, and observed consumer groups.

## Explicitly Deferred

- Multiple generated topics per Async Channel and desired instance quantity.
- Topic and claim migration strategies.
- Async Channel types other than `kafka-topic`.
- Agent detail and edit screens, and agent deletion safeguards.
- Credentials and secret handling for agent connections, including masking and rotation.
- Agent health, liveness, version, and connection testing beyond the stale/connected indicator.
- Agent types and capabilities beyond Cluster Provider, Resource Provider, Telemetry Agent, and Custom.
- The governance evaluation model: how weight resolves conflicts, ordering, cooldown and anti-thrash, and per-field action constraints.
- Policy exceptions, approval queues for advisory actions, and the telemetry protocol wire format.
- Client credentials, token issuance and rotation, and connection testing.
- Consumer-group configuration (offset reset and similar) and any registered group entity — groups are telemetry-observed only.
- Client detail beyond identity, labels, derived access, and observed groups.
- Capacity and health telemetry behavior beyond named indicators.
- Cluster upgrades, drains, and real-world connectivity configuration.
- Advanced placement validation and selection controls.

## Related Domain Specifications

- [Kafka Cluster](../003-franz/003.3-kafka-cluster.md)
- [Async Channel](../003-franz/003.4-async-channel.md)
- [Access Policy](../003-franz/003.5-access-policy.md)
- [Kafka Topic](../003-franz/003.6-kafka-topic.md)
- [Placement & Selection](../003-franz/003.7-placement-and-selection.md)
- [Governance](../003-franz/003.8-governance.md)
- [Agents](../003-franz/003.9-agents.md)
- [Clients](../003-franz/003.10-clients.md)
- [API contract](../../franz/api/franz/v1/)
