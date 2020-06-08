#!/bin/bash

set -euv

function wait_for_tx () {
    until (enigmacli q tx "$1" &> /dev/null)
    do
        echo "$2"
        sleep 1
    done
}

until (enigmacli status 2>&1 | jq -e '(.sync_info.latest_block_height | tonumber) > 0' &> /dev/null)
do
    echo "Waiting for chain to start..."
    sleep 1
done


# store wasm code on-chain so we could later instansiate it
wget -O /tmp/contract.wasm https://raw.githubusercontent.com/CosmWasm/cosmwasm-examples/f5ea00a85247abae8f8cbcba301f94ef21c66087/erc20/contract.wasm --no-check-certificate
STORE_TX_HASH=$(
    yes |
    enigmacli tx compute store /tmp/contract.wasm --from a --gas 10000000 |
    jq -r .txhash
)

wait_for_tx "$STORE_TX_HASH" "Waiting for store to finish on-chain..."

# test storing of wasm code (this doesn't touch sgx yet)
enigmacli q tx "$STORE_TX_HASH" |
    jq -e '.logs[].events[].attributes[] | select(.key == "code_id" and .value == "1")'

# init the contract (ocall_init + write_db + canonicalize_address)
# a is a tendermint address (will be used in transfer: https://github.com/CosmWasm/cosmwasm-examples/blob/f2f0568ebc90d812bcfaa0ef5eb1da149a951552/erc20/src/contract.rs#L110)
# enigma1f395p0gg67mmfd5zcqvpnp9cxnu0hg6rp5vqd4 is just a random address
# balances are set to 108 & 53 at init
INIT_TX_HASH=$(
    yes |
        enigmacli tx compute instantiate 1 "{\"decimals\":10,\"initial_balances\":[{\"address\":\"$(enigmacli keys show a -a)\",\"amount\":\"108\"},{\"address\":\"enigma1f395p0gg67mmfd5zcqvpnp9cxnu0hg6rp5vqd4\",\"amount\":\"53\"}],\"name\":\"ReuvenPersonalRustCoin\",\"symbol\":\"RPRC\"}" --label RPRCCoin --from a |
        jq -r .txhash
)

wait_for_tx "$INIT_TX_HASH" "Waiting for instantiate to finish on-chain..."

CONTRACT_ADDRESS=$(
    enigmacli q tx "$INIT_TX_HASH" |
        jq -er '.logs[].events[].attributes[] | select(.key == "contract_address") | .value'
)

# test balances after init (ocall_query + read_db + canonicalize_address)
enigmacli q compute contract-state smart "$CONTRACT_ADDRESS" "{\"balance\":{\"address\":\"$(enigmacli keys show a -a)\"}}" |
    jq -e '.balance == "108"'
enigmacli q compute contract-state smart "$CONTRACT_ADDRESS" "{\"balance\":{\"address\":\"enigma1f395p0gg67mmfd5zcqvpnp9cxnu0hg6rp5vqd4\"}}" |
    jq -e '.balance == "53"'

# transfer 10 balance (ocall_handle + read_db + write_db + humanize_address + canonicalize_address)
TRANSFER_TX_HASH=$(
    yes |
        enigmacli tx compute execute --from a "$CONTRACT_ADDRESS" '{"transfer":{"amount":"10","recipient":"enigma1f395p0gg67mmfd5zcqvpnp9cxnu0hg6rp5vqd4"}}' 2> /dev/null |
        jq -r .txhash
)

wait_for_tx "$TRANSFER_TX_HASH" "Waiting for transfer to finish on-chain..."

# test balances after transfer (ocall_query + read_db)
enigmacli q compute contract-state smart "$CONTRACT_ADDRESS" "{\"balance\":{\"address\":\"$(enigmacli keys show a -a)\"}}" |
    jq -e '.balance == "98"'
enigmacli q compute contract-state smart "$CONTRACT_ADDRESS" "{\"balance\":{\"address\":\"enigma1f395p0gg67mmfd5zcqvpnp9cxnu0hg6rp5vqd4\"}}" |
    jq -e '.balance == "63"'


echo "All is done. Yay!"