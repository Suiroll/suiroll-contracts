# Suiroll Smart Contracts

## Run local Validator

### Start Validator
`RUST_LOG="consensus=off" sui-test-validator`


### Request SUI from faucet

```bash
curl --location --request POST 'http://127.0.0.1:9123/gas' \
--header 'Content-Type: application/json' \
--data-raw '{
    "FixedAmountRequest": {
        "recipient": "0x63d8e83e800ad251320f1d28ae0bf421385b35dcc683994251a0d276e7ccb8a0"
    }
}'
```


## Publish packages

`yarn deploy`
