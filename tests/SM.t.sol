pragma solidity ^0.8.19;

import "forge-std/Test.sol";

interface Redis {
    function set(string memory key, bytes memory value) external returns (bytes memory, string memory);
}

contract SM {
    function getService(string memory service_name, bytes memory config) public returns (Service service, bytes memory err) {
        return (new Service(address(this), keccak256(abi.encode(service_name, config))), bytes(""));
    }
    function callService(bytes32 handle, bytes memory cdata) public returns (bytes memory) {
        return abi.encode(cdata, "xxxx");
    }
}

contract Service {
    address sm;
    bytes32 handle;
    constructor(address _sm, bytes32 _handle) {
        sm = _sm;
        handle = _handle;
    }

    fallback(bytes calldata cdata) external returns (bytes memory) {
        return SM(sm).callService(handle, cdata);
    }
}

contract SMTest is Test {
    SM sm;

    function setUp() public {
        sm = new SM();
    }

    function test_call() public {
        (Service s, bytes memory err) = sm.getService("redis", bytes(""));
        assertTrue(err.length == 0);

        Redis r = Redis(address(s));
        (bytes memory data_in, string memory str_out) = r.set("xaxa", bytes("hoho"));
        assertEq(str_out, "xxxx");
        assertEq(data_in, abi.encodeWithSelector(Redis.set.selector, "xaxa", bytes("hoho")));
    }
}
