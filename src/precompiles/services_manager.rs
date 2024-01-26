use crate::u64_to_address;
use ethers;
use ethers::contract::BaseContract;
use ethers::core::abi::{parse_abi, AbiEncode};
use ethers::types::{Bytes, H256};
use lazy_static::lazy_static;
use reqwest::blocking::Client as ReqwestClient;
use revm::precompile::{
    EnvPrecompileFn, Precompile, PrecompileError, PrecompileResult, PrecompileWithAddress,
};
use revm::primitives::Env;
use revm::primitives::Address as RevmAddress;
use std;
use std::collections::HashMap;
use std::sync::Mutex;

pub const RUN: PrecompileWithAddress = PrecompileWithAddress::new(
    u64_to_address(0x50700),
    Precompile::Env(run as EnvPrecompileFn),
);

lazy_static! {
    static ref SM_ABI: BaseContract = parse_abi(&[
        "function getService(string memory service_name, bytes memory config) external returns (bytes32 handle, bytes memory err)",
        "function callService(bytes32 handle, bytes memory cdata) external returns (bytes memory)",
    ]).unwrap().into();
}

pub struct ServicesManager {
    pub service_handles: HashMap<H256, (RevmAddress, H256)>,
}

impl ServicesManager {
    pub fn new() -> Self {
        ServicesManager {
            service_handles: HashMap::new(),
        }
    }
}

lazy_static! {
    static ref GLOBAL_SM: Mutex<ServicesManager> = Mutex::new(ServicesManager::new());
}

const INSTANTIATE_FAILED: PrecompileError =
    PrecompileError::CustomPrecompileError("could not instantiate requested protocol");
const INCORRECT_INPUTS: PrecompileError =
    PrecompileError::CustomPrecompileError("incorrect inputs passed in");
const SERIVCE_MISCONFIGURED: PrecompileError =
    PrecompileError::CustomPrecompileError("service is misconfigured");
const SERIVCE_REQUEST_FAILED: PrecompileError =
    PrecompileError::CustomPrecompileError("request to service failed");

fn run(input: &[u8], gas_limit: u64, env: &Env) -> PrecompileResult {
    if let Some(called_fn) = SM_ABI.methods.get(&input[0..4]) {
        match called_fn.0.as_str() {
            "getService" => get_service(input, gas_limit, env),
            "callService" => call_service(input, gas_limit, env),
            _ => Err(INCORRECT_INPUTS),
        }
    } else {
        Err(INCORRECT_INPUTS)
    }
}

fn get_service(input: &[u8], gas_limit: u64, env: &Env) -> PrecompileResult {
    let gas_used = 10000 as u64;
    if gas_used > gas_limit {
        return Err(PrecompileError::OutOfGas);
    }

    let (serivce, config): (String, Bytes) =
        SM_ABI.decode_input(input).map_err(|_e| INCORRECT_INPUTS)?;

    // TODO: configure elsewhere
    let instantiate_resp_raw = send_to_requests_manager(
        &config.0,
        format!("http://127.0.0.1:5605/instantiate/{}", &serivce).as_str(),
    );
    if let Err(e) = instantiate_resp_raw {
        let mut ret = ethers::types::Address::zero().encode();
        ret.extend(Bytes::from_iter(e.to_string().as_bytes().into_iter()).encode());
        return Ok((gas_used, ret));
    };

    // Handle should really just be a salted hash of the (service_name, config)
    let instantiate_resp = instantiate_resp_raw.unwrap();
    if instantiate_resp.len() != 32 {
        return Err(INSTANTIATE_FAILED);
    }
    let service_handle: H256 = H256::from_slice(instantiate_resp.as_slice());
    let contract_handle = H256::random();

    // Only whoever knows the random handle can access the service
    // Should probably be done at the contract level using secure random
    GLOBAL_SM.lock().unwrap()
        .service_handles
        .insert(contract_handle, (env.msg.caller, service_handle));

    let mut ret = service_handle.encode();
    ret.extend(ethers::abi::Bytes::new());
    Ok((gas_used, ret))
}

fn call_service(input: &[u8], gas_limit: u64, env: &Env) -> PrecompileResult {
    let gas_used = 10000 as u64;
    if gas_used > gas_limit {
        return Err(PrecompileError::OutOfGas);
    }

    let (contract_handle, service_calldata): (H256, Bytes) =
        SM_ABI.decode_input(input).map_err(|_e| INCORRECT_INPUTS)?;

    let locked_sm = GLOBAL_SM.lock().unwrap();
    let service_handle = match locked_sm.service_handles.get(&contract_handle) {
        None => Err(SERIVCE_MISCONFIGURED),
        Some(sh) => {
            if !sh.0.const_eq(&env.msg.caller) {
                return Err(SERIVCE_MISCONFIGURED)
            }
            Ok(sh.1)
        }
    }?;

    match send_to_requests_manager(
        &service_calldata.0,
        &format!("http://127.0.0.1:5605/request/{:?}", &service_handle),
    ) {
        Err(_e) => PrecompileResult::Err(SERIVCE_REQUEST_FAILED),
        Ok(r) => PrecompileResult::Ok((gas_used, r)),
    }
}

fn send_to_requests_manager(input: &[u8], path: &str) -> reqwest::Result<Vec<u8>> {
    let client = ReqwestClient::new();
    // TODO: configure elsewhere
    let res = client.post(path).body::<Vec<u8>>(input.into()).send()?;

    let resp_bytes = res.bytes()?;
    Ok(resp_bytes.into())
}
