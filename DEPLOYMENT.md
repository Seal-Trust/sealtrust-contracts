# SealTrust - Sui Testnet Deployment

**Deployment Date**: November 22, 2025
**Network**: Sui Testnet
**Status**: LIVE

---

## Deployed Packages

### SealTrust Verification Package
| Property | Value |
|----------|-------|
| **Package ID** | `0xcdc25c90e328f2905c97c01e90424395dd7b10e67769fc8f4ae62b87f1e63e4e` |
| **Module** | `sealtrust` |
| **Witness** | `SEALTRUST` |
| **Sui Explorer** | [View on SuiVision](https://testnet.suivision.xyz/package/0xcdc25c90e328f2905c97c01e90424395dd7b10e67769fc8f4ae62b87f1e63e4e) |

### Enclave Package (Mysten Labs)
| Property | Value |
|----------|-------|
| **Package ID** | `0x0ff344b5b6f07b79b56a4ce1e9b1ef5a96ba219f6e6f2c49f194dee29dfc8b7f` |
| **Module** | `enclave` |
| **Publisher** | Mysten Labs (Official Nautilus) |

---

## On-Chain Objects

### EnclaveConfig (Shared)
| Property | Value |
|----------|-------|
| **Object ID** | `0x55d6a15a5e8822b39f76dc53031d83beddc1e5b0e3ef804b82e8d4bfe4fbdc32` |
| **Type** | `EnclaveConfig<sealtrust::SEALTRUST>` |
| **Name** | `sealtrust dataset enclave` |
| **Sui Explorer** | [View on SuiVision](https://testnet.suivision.xyz/object/0x55d6a15a5e8822b39f76dc53031d83beddc1e5b0e3ef804b82e8d4bfe4fbdc32) |

### Enclave (Shared) - Registered with AWS Nitro
| Property | Value |
|----------|-------|
| **Object ID** | `PENDING - Will be updated after registration` |
| **Type** | `Enclave<sealtrust::SEALTRUST>` |
| **Sui Explorer** | PENDING |

---

## PCR Measurements (AWS Nitro Enclave)

PCR values prove the exact code running inside the TEE:

```
PCR0: b13c459767dfa980fc070317cced783437b0198963564bd5f906a5b35f209f8104e1ddbc64ad0615842c6a243e0b6758
PCR1: b13c459767dfa980fc070317cced783437b0198963564bd5f906a5b35f209f8104e1ddbc64ad0615842c6a243e0b6758
PCR2: 21b9efbc184807662e966d34f390821309eeac6802309798826296bf3e8bec7c10edb30948c90ba67310f7b964fc500a
```

| PCR | Description |
|-----|-------------|
| PCR0 | Enclave image file hash |
| PCR1 | Linux kernel hash |
| PCR2 | Application binary hash |

---

## Transaction History

| Action | Transaction Digest | Date |
|--------|-------------------|------|
| Publish SealTrust Package | `CLPTKZW9Kxf2JXWkQxfU8b9FQXVwNAkvioWm5d6knoVb` | 2025-11-22 |
| Update PCRs | `6xDy1W8M4SRocEpDvch8tNRMfLR6Qq1UR8VWEX5Rjhu5` | 2025-11-22 |
| Register Enclave | PENDING | 2025-11-22 |

---

## AWS Infrastructure

### Nautilus Enclave (Production)
| Property | Value |
|----------|-------|
| **Public URL** | `http://13.217.44.235:3000` |
| **Instance Type** | `m5a.xlarge` |
| **Region** | `ap-northeast-1` |
| **Enclave CID** | `22` |
| **Memory** | `1024 MiB` |
| **CPUs** | `2` |

### API Endpoints
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Simple health check |
| `/health_check` | GET | Full health check with endpoint status |
| `/get_attestation` | GET | Get NSM attestation document |
| `/verify_metadata` | POST | Verify and sign dataset metadata |

### Test the Enclave
```bash
# Health check
curl http://13.217.44.235:3000/health

# Get attestation (returns PCRs + public key)
curl http://13.217.44.235:3000/get_attestation
```

---

## How to Verify

### 1. Verify Package Deployment
```bash
sui client object 0xcdc25c90e328f2905c97c01e90424395dd7b10e67769fc8f4ae62b87f1e63e4e
```

### 2. Verify EnclaveConfig Has Real PCRs
```bash
sui client object 0x55d6a15a5e8822b39f76dc53031d83beddc1e5b0e3ef804b82e8d4bfe4fbdc32
```

### 3. Verify Enclave is Running
```bash
curl http://13.217.44.235:3000/health
# Returns: "OK"
```

### 4. Verify PCR Values Match
```bash
curl http://13.217.44.235:3000/get_attestation | jq '.pcrs'
# Should match the PCR values above
```

---

## Integration

### Frontend Configuration
```typescript
export const CONFIG = {
  // Network
  NETWORK: 'testnet',

  // Packages
  VERIFICATION_PACKAGE: '0xcdc25c90e328f2905c97c01e90424395dd7b10e67769fc8f4ae62b87f1e63e4e',
  ENCLAVE_PACKAGE: '0x0ff344b5b6f07b79b56a4ce1e9b1ef5a96ba219f6e6f2c49f194dee29dfc8b7f',

  // Objects
  ENCLAVE_CONFIG_ID: '0x55d6a15a5e8822b39f76dc53031d83beddc1e5b0e3ef804b82e8d4bfe4fbdc32',
  ENCLAVE_ID: 'PENDING', // Update after registration

  // Nautilus
  NAUTILUS_URL: 'http://13.217.44.235:3000',
};
```

### Move Contract Calls
```typescript
// Register dataset with TEE verification
tx.moveCall({
  target: `${VERIFICATION_PACKAGE}::sealtrust::register_dataset`,
  typeArguments: [`${VERIFICATION_PACKAGE}::sealtrust::SEALTRUST`],
  arguments: [
    // ... metadata arguments
    tx.object(ENCLAVE_ID),  // The registered Enclave object
  ],
});
```

---

## GitHub Repositories

| Repository | URL |
|------------|-----|
| **Frontend** | https://github.com/Seal-Trust/sealtrust-frontend |
| **Contracts** | https://github.com/Seal-Trust/sealtrust-contracts |
| **Enclave** | https://github.com/Seal-Trust/sealtrust-enclave |

---

*Last Updated: November 22, 2025*
