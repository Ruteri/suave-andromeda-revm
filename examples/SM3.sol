pragma solidity ^0.8.19;

interface Redis {
    function set(string memory key, bytes memory value) external returns (bytes memory);
    function get(string memory key) external returns (bytes memory);
    function publish(string memory topic, bytes memory msg) external;

    function subscribe(string memory topic, RedisSubscriber subscriber/* filter? */) external;
}

interface RedisSubscriber {
    function onRedisMessage(string memory topic, bytes memory msg) external;
}


interface Builder {
    struct Config {
        uint256 chainId;
    }
    struct Bundle {
        uint256 height;
        bytes transaction;
        uint256 profit;
    }
    struct SimResult {
        uint256 profit;
    }
    struct Block {
        uint256 profit;
    }

    function newSession() external returns (string memory sessionId);
    function addTransaction(string memory sessionId, bytes memory tx) external returns (SimResult memory);

    function simulate(Bundle memory bundle) external returns (SimResult memory);
    function buildBlock(Bundle[] memory bundle) external returns (Block memory);
}


address constant SM_ADDR = address(0x07); // Can be a library, a precompile, or a contract

interface SM {
    function getService(string memory service_name, bytes memory config) external returns (bytes32 handle, bytes memory err);
    function callService(bytes32 handle, bytes memory cdata) external returns (bytes memory);
}

contract Service {
    bytes32 handle;
    constructor(bytes32 _handle) {
        handle = _handle;
    }

    fallback(bytes calldata cdata) external returns (bytes memory) {
        return SM(SM_ADDR).callService(handle, cdata);
    }
}

contract WithRedis {
    function redis() internal returns (Redis) {
        (bytes32 handle, bytes memory err) = SM(SM_ADDR).getService("redis", bytes(""));
        require(err.length == 0, string(abi.encodePacked("could not initialize redis: ", string(err))));
        return Redis(address(new Service(handle)));
    }
}

contract WithBuilder {
    Builder.Config config; // onchain!

    constructor(uint256 chainId) {
        config = Builder.Config(chainId);
    }

    function builder() internal returns (Builder) {
        (bytes32 handle, bytes memory err) = SM(SM_ADDR).getService("builder", abi.encode(config));
        require(err.length == 0, string(abi.encodePacked("could not initialize builder: ", string(err))));
        return Builder(address(new Service(handle)));
    }
}

uint256 constant GOERLI_CHAINID = 5;

contract DBB is WithRedis, WithBuilder, RedisSubscriber {
    // SM could also be a contract passed in here
    constructor() WithRedis() WithBuilder(GOERLI_CHAINID) {}

    function addBundle(Builder.Bundle memory bundle) public {
        Redis r = redis();
        Builder b = builder();

        bundle.profit = b.simulate(bundle).profit;
        internal_addBundle(r, bundle);

        // Note: bundle already includes profit, does not have to be re-calculated
        r.publish("bundles", abi.encode(bundle));
    }

    function internal_addBundle(Redis r, Builder.Bundle memory bundle) internal {
        bytes32 bundleHash = keccak256(abi.encode(bundle));
        r.set(string(abi.encodePacked("bundle-", bundleHash)), abi.encode(bundle));
        bytes32[] memory c_bundles = abi.decode(r.get("bundles"), (bytes32[]));
        bytes32[] memory n_bundles = new bytes32[](c_bundles.length+1);
        n_bundles[c_bundles.length] = bundleHash;
        for (uint i = 0; i < c_bundles.length; i++) {
            n_bundles[i] = c_bundles[i];
        }
        r.set("bundles", abi.encode(n_bundles));

        /* Could also order by profit already too */
    }

    function subscribeBundles() external {
        redis().subscribe("bundles", RedisSubscriber(this));
    }

    function onRedisMessage(string memory topic, bytes memory data) external {
        if (strEqual(topic, "bundles")) {
            internal_addBundle(redis(), abi.decode(data, (Builder.Bundle)));
        } else if (strEqual(topic, "blocks")) {
            /* ... */
        }
    }

    function buildBlock() public {
        Redis r = redis();
        Builder b = builder();
    }
}

function strEqual(string memory a, string memory b) pure returns (bool) {
    return bytes(a).length == bytes(b).length && keccak256(bytes(a)) == keccak256(bytes(b));
}
