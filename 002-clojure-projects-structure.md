# Base structure

### Depedencies
- [Leinigen](https://leiningen.org/)
- [Clojure](https://clojure.org/) 
- [Plumatic Schema](https://github.com/plumatic/schema)

### Clojure Project Concepts

| Concept | Description |
|---|---|
| **adapters** | transform datas from wire to models and models to wire |
| **clients** | Has the components to connect to external dependencies, like kafka, postgres and and so on |
| **components** | components with start/stop lifecicle and some state |
| **controllers** | connect the components, clients, logic, wire with in/out |
| **logic** | do the logic, no i/o or side effect functions |
| **models** | internal schemas to make code/data easy to understand |
| **ops** | operational stuffs |
| **wire** | Contains the schema for data received from the wire (like kafka or HTTP) |
| **unit test** | unit tests, does not depend of external resources, mock the dependencies. more exhaustive tests, specially in function with no side effects |
| **integratin test** | test the code against real/stub dependencies. Test the whole flow, specially the happy path |


### Folder Structure
```
grete-samsa/
    resources/                         ;; config and other resources
    src/grete_samsa/
      clients/                         ;; clients to connect to external deps
      components/                      ;; components
      controllers/                     ;; controllers
      logic/                           ;; service logic namespaces
      models/                          ;; internal model schema and adapters
      ops/                             ;; ops logic
      wire/                            ;; schema in/out
      core.clj                         ;; -main entry point
      system.clj                       ;; component system map
    test/grete_samsa/
      unit/                            ;; unit tests
      integration/                     ;; integration tests
      helpers/                         ;; test helpers
```

### HTTP Api

All the capabilities are provided under the `api/` path, having a version right after and the capability alias with any other information require to process the request.
For instance, an endpoint to create (POST) a new topic could look like this: `/api/v0/topic/create`, a endpoint to list (GET) the topics `/api/v0/topic/list` and a endpoint to see a specific topic `/api/v0/topic/get/:topic_name`

### References

- [Kafka repo](https://github.com/apache/kafka)