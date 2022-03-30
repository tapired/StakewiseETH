import brownie
from brownie import Contract
import pytest

def test_swap_reverts(
    chain,
    accounts,
    token,
    vault,
    strategy,
    user,
    strategist,
    amount,
    RELATIVE_APPROX,
    gov,
    rewards,
    keeper,
):
    weth = Contract("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
    seth2 = Contract("0xFe2e637202056d30016725477c5da089Ab0A043A")
    reth2 = Contract("0x20BC832ca081b91433ff6c17f85701B6e92486c5")
    oracle = Contract("0x8a887282E67ff41d36C0b7537eAB035291461AcD")

    reserve = accounts.at("0xE78388b4CE79068e89Bf8aA7f218eF6b9AB0e9d0", force=True)
    weth.transfer(user, 20_000, {"from": reserve})
    vault.setManagementFee(0,{"from":gov})
    vault.setPerformanceFee(0,{"from":gov})
    token.approve(vault.address, weth.balanceOf(user), {"from": user})
    vault.deposit(weth.balanceOf(user), {"from": user})
    assert token.balanceOf(vault.address) == 20_000 + amount

    with brownie.reverts("Too little received"):
        strategy.harvest()
    strategy.setSwapTosETH2(False,{"from":gov})
    strategy.harvest()
    chain.sleep(1)
    chain.mine(1)
    print("strategy has", strategy.estimatedTotalAssets())
