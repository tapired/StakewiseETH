import brownie
from brownie import Contract
import pytest


def test_profitable_harvest(
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
    seth2 = Contract("0xFe2e637202056d30016725477c5da089Ab0A043A")
    reth2 = Contract("0x20BC832ca081b91433ff6c17f85701B6e92486c5")
    oracle = Contract("0x8a887282E67ff41d36C0b7537eAB035291461AcD")

    # Deposit to the vault
    vault.setManagementFee(0,{"from":gov})
    vault.setPerformanceFee(0,{"from":gov})
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    strategy.harvest()
    chain.sleep(1)
    chain.mine(1)
    print("strategy has", strategy.estimatedTotalAssets())
    # assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    # strategy.setSwapTosETH2(False,{"from":gov}) # instead of swapping we stake and mint 1:1

    reth2.updateTotalRewards(1700000000000000000000,{"from":oracle})
    chain.sleep(86400 * 5)
    chain.mine(1)
    print("strategy has reth", reth2.balanceOf(strategy))
    strategy.harvest()
    print("strategy has", strategy.estimatedTotalAssets())

    reth2.updateTotalRewards(1800000000000000000000,{"from":oracle})
    chain.sleep(86400 * 5)
    chain.mine(1)
    print("strategy has reth", reth2.balanceOf(strategy))
    strategy.harvest()
    print("strategy has", strategy.estimatedTotalAssets())

    reth2.updateTotalRewards(1900000000000000000000,{"from":oracle})
    chain.sleep(86400 * 5)
    chain.mine(1)
    print("strategy has reth", reth2.balanceOf(strategy))
    strategy.harvest()
    print("strategy has", strategy.estimatedTotalAssets())

    reth2.updateTotalRewards(2000000000000000000000,{"from":oracle})
    chain.sleep(86400 * 5)
    chain.mine(1)
    print("strategy has reth", reth2.balanceOf(strategy))
    strategy.harvest()
    print("strategy has", strategy.estimatedTotalAssets())

    reth2.updateTotalRewards(2100000000000000000000,{"from":oracle})
    chain.sleep(86400 * 5)
    chain.mine(1)
    print("strategy has reth", reth2.balanceOf(strategy))
    strategy.harvest()
    print("strategy has", strategy.estimatedTotalAssets())

    reth2.updateTotalRewards(2200000000000000000000,{"from":oracle})
    chain.sleep(86400 * 5)
    chain.mine(1)
    print("strategy has reth", reth2.balanceOf(strategy))
    strategy.harvest()
    print("strategy has", strategy.estimatedTotalAssets())

    print("strategist reward", vault.balanceOf(strategy))
    # print("governance fee", vault.balanceOf(rewards))
    #
    # vault.transferFrom(
    #     strategy, strategist, vault.balanceOf(strategy), {"from": strategist}
    # )
    # vault.withdraw({"from": rewards})
    # print("strategy has after fee withdrawn from governance", strategy.estimatedTotalAssets())
    # vault.withdraw({"from": strategist})
    # print("strategy has after fee withdrawn from strategist", strategy.estimatedTotalAssets())
    tx = vault.withdraw(vault.balanceOf(user),user,100,{"from":user})
    print("user weth balance after all:" , token.balanceOf(user))
