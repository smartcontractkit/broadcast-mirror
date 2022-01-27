<div id="top"></div>
<h3 align="center">Broadcast Mirror</h3>
</div>

<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#features">Features</a></li>
        <li><a href="#built-with">Built With</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#provider-configuration">Provider Configuration</a></li>
        <li><a href="#building">Building</a></li>
        <li><a href="#adding-accounts">Adding Accounts</a></li>
      </ul>
    </li>
    <li>
      <a href="#usage">Usage</a>
      <ul>
        <li><a href="#with-a-chainlink-node">With a Chainlink Node</a></li>
        <li><a href="#transaction-deduplication">Transaction Deduplication</a></li>
      </ul>
    </li>
    <li>
      <a href="#logging-and-monitoring">Logging and Monitoring</a>
      <ul>
        <li><a href="#common-error-messages">Common Error Messages</a></li>
      </ul>
    </li>
    <li>
      <a href="#contributing">Contributing</a>
      <ul>
        <li><a href="#code-style">Code Style</a></li>
        <li><a href="#testing">Testing</a></li>
      </ul>
    </li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
  </ol>
</details>



<!-- ABOUT THE PROJECT -->
## About The Project

The purpose of this service is to fan out transaction transmissions to all available mempools. This increases the security of the Chainlink network by removing the risk of transactions being sent only to private mempools. Additionally, it eliminates the "black hole" problem, which we've witnessed across multiple networks and EVM clients, where transactions are broadcast but fail to be relayed beyond your primary EVM client connection. Ultimately, this will help transactions be confirmed as quickly as possible, cutting down on the chance of reverts and increasing network profitability.

At the moment we have tested with ETH mainnet & testnet, as well as other EVM chains (MATIC & BSC). While other EVM network RPC providers remain untested, they should be supported without any changes (just add them to your `networks.json` config), assuming they support the same JSON-RPC API with `eth_sendRawTransaction`.

### Features
- lightweight and performant: only uses nginx worker processes, all request parsing and mirroring happens via (non-blocking) lua threads
- support for multiple network types and groups of RPC providers
- daisy-chain support, for chaining multiple broadcast mirrors together
- deduplication of incoming transactions, to avoid consuming API quotas with already-seen requests

<p align="right">(<a href="#top">back to top</a>)</p>



### Built With

* [OpenResty](https://openresty.org/en/)
* [NGINX](https://www.nginx.com/)
* [Lua](https://www.lua.org/)
* [Docker](https://www.docker.com/)

<p align="right">(<a href="#top">back to top</a>)</p>



<!-- GETTING STARTED -->
## Getting Started

### Prerequisites

* docker / docker-compose
* pipenv (for testing only)
  ```sh
  pip install --user pipenv
  ```
* API keys (if necessary) for RPC provider(s) you wish to mirror transaction requests to
* Clone the repo
   ```sh
   git clone https://github.com/smartcontractkit/broadcast-mirror.git
   ```

### Provider Configuration
This service can mirror ETH transaction broadcasts to a variety of existing RPC API providers. Generally, it should be straightforward to integrate any provider you want, assuming they have a JSON-RPC compliant API. See the <a href="#supported-provider-types">Supported Provider Types</a> section for more detail. For configuration, you will need all necessary API keys or other credentials.

Provider configurations are stored in <a href="src/networks.json">src/networks.json</a>. The top-level keys indicate which providers should be used for each network and then each list item specifies provider details. The top-level key should be set to an integer that indicates the `chain_id` for the corresponding network (e.g. `1` for ETH Mainnet, `137` for Polygon Mainnet, or `56` for BSC Mainnet). See [Chainlist](https://chainlist.org/) as a reference.

* `name` only for logging purposes
* `type` one of `json-rpc, json-rpc-with-basic-auth, etherscan` depending on your provider (most will be `json-rpc`)
* `uri` the URL where transactions should be mirrored to, including any necessary API keys or query parameters. The service will typically deliver transaction data in the body of a POST request to this URL (depending on provider type).

**Note:** If you wish to run a separate container for each network, you can specify the `ETH_NETWORK` environment variable. If `ETH_NETWORK` _is_ specified, it will only respond to requests for that specific chain, and any `chain_id` URL parameter will be ignored. If it _is not_ specified (the default), the container will attempt to look up the corresponding `chain_id` specified in the request URL and map it to the available providers in `networks.json`.

#### Supported Provider Types
Currently the service supports three methods of authentication and relaying transactions. See <a href="src/networks.json">src/networks.json</a> for examples.
- `json-rpc` for services compliant with the JSON-RPC spec. For example, local nodes or RPC API providers (e.g. no auth, or the API key is a URL parameter)
- `json-rpc-with-basic-auth` as above, but if the provider expects authentication via HTTP basic auth instead
- `etherscan` specific to Etherscan's API


### Adding Accounts

1. Users should generate basic auth hashes with `htpasswd` (using bcrypt) and provide them to you
   ```sh
   htpasswd -Bn user123
   ```
2. Add the htpasswd output to `authorized_users`
   ```sh
   vim src/authorized_users
   ```
3. Rebuild and restart container

### Building

1. Install deps
   ```sh
   cd broadcast-mirror && pipenv install
   ```
2. Configure settings and add accounts (see above)
3. Build
   ```sh
   docker-compose build
   ```

<p align="right">(<a href="#top">back to top</a>)</p>



<!-- USAGE EXAMPLES -->
## Usage

Basic docker-compose example included. For production use, this must be run behind a reverse proxy that can provide HTTPS termination (e.g. k8s ingress-nginx or traefik).

The service expects `eth_sendRawTransaction` requests in standard JSON-RPC format. It will ignore any request that is not an HTTP POST with `"method":"eth_sendRawTransaction"`. The service can accept batched requests.

Your request should include `chain_id` as a URL parameter, with the value set to the [chain id](https://chainlist.org/) of the network you are broadcasting transactions for.

The service returns `HTTP 200` upon receipt of a properly formatted request and `HTTP 400` for all other invalid requests. `HTTP 401` is returned to unauthorized users.

1. Run local development environment
   ```sh
   docker-compose up -d
   ```

### With a Chainlink Node
A Chainlink Node can leverage a broadcast mirror by setting the [ETH\_SECONDARY\_URLS](https://docs.chain.link/docs/configuration-variables/#eth_secondary_urls) env var
```
ETH_SECONDARY_URLS="https://user123:passABC@broadcast-mirror-host.example/?chain_id=N"
```

### Transaction Deduplication
The service hashes all incoming transaction data and maintains a set of these already-process transactions. If the hash of an incoming transaction matches an existing hash in the set, the new transaction is not processed any further. This mitigates the potential for overrunning your RPC API quota(s) and avoids any loop scenarios where one broadcast mirror is configured to daisy-chain into another. Please note the list of seen transactions is stored in-memory and would be cleared by a service restart and seen transaction state would not be shared if multiple broadcast mirror services were run behind a load-balancer.

<p align="right">(<a href="#top">back to top</a>)</p>



## Logging and Monitoring

Logs are output via standard nginx logging mechanisms, to stdout and stderr in JSON format. It is suggested to collect logs and inspect the `log_level, msg, error` fields for indication of any service issues. For example, high rates of `msg = "Provider returned error"` could indicate a configuration problem (you used an incorrect API key / hostname), while `msg = "Provider error broadcasting transaction"` typically indicates the sent transaction already exists in the provider's mempool.

```
broadcast-mirror  | 2021/12/01 00:00:00 [warn] 8#8: *2 [lua] broadcast.lua:23: log(): {"error":{"message":"already known","code":-32000},"remote_user":"user123","log_level":5,"msg":"Provider error broadcasting transaction","request_id":"abc123","network":"Mainnet","provider":"Testing Provider"}, context: ngx.timer, client: 172.10.0.1, server: 0.0.0.0:8080
```

Monitoring the number of log messages with `log_level` of `5` (warning) or `4` (error) is a good place to start.

### Common Error Messages

The `error` field is populated whenever a provider responds with a non HTTP 200 code. Inspecting the `error.message` field will shed more light on the specific reason. Some of these "errors" may be expected, common ones are noted below:
- `msg = "Provider error broadcasting transaction"` indicates the provider received the transaction you relayed, but could not process it
  - `error.message = "already known"` indicates the provider has already seen the transaction you have relayed, this is common and expected
- `msg = "Transaction already seen, skipping."` indicates the broadcast mirror service has already seen this exact transaction and will not relay it
- `msg = "Provider returned error"` indicates the provider _did not_ receive the transaction you relayed, typically this is caused by a service disruption on the provider's side

<p align="right">(<a href="#top">back to top</a>)</p>



<!-- CONTRIBUTING -->
## Contributing

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag "enhancement".

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

### Code Style
```
pipenv install --dev
pipenv run nginxfmt src/nginx.conf		# ensure nginxfmt is used for any changes to nginx.conf
pipenv run black tests/test_broadcast.py	# ensure black is used for any changes to python tests
```

Please run [StyLua](https://github.com/JohnnyMorganz/StyLua) if changing any lua files.

```
stylua --column-width=120 --indent-type=spaces --line-endings=unix src/broadcast.lua
```

### Testing
Tests currently ensure malformed input is ignored and valid inputs (single or batched txns) are accepted.

```
pipenv install
pipenv run pytest -v
```

<p align="right">(<a href="#top">back to top</a>)</p>



<!-- LICENSE -->
## License

Distributed under the MIT License. See `LICENSE` for more information.

<p align="right">(<a href="#top">back to top</a>)</p>



<!-- CONTACT -->
## Contact

Project Link: [https://github.com/smartcontractkit/broadcast-mirror](https://github.com/smartcontractkit/broadcast-mirror)

<p align="right">(<a href="#top">back to top</a>)</p>
