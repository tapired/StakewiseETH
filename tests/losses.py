import brownie
from brownie import Contract
from utils import checks
import pytest

def test_losewithdrawal(
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

 # for this test we will make the initial amount that strategy can hold to 15k ETH (amount is 15k eth)
 #
 oracle = Contract("0x8a887282E67ff41d36C0b7537eAB035291461AcD")
 reth2 = Contract("0x20BC832ca081b91433ff6c17f85701B6e92486c5")

 token.approve(vault.address, amount, {"from": user})
 vault.deposit(amount, {"from": user})
 assert token.balanceOf(vault.address) == amount

 strategy.harvest()
 chain.sleep(1)
 chain.mine(1)
 assert strategy.estimatedTotalAssets() <= amount  # thats our first lose when we swap eth to seth2

 print("strategy has", strategy.estimatedTotalAssets())
 initial_loss = amount - strategy.estimatedTotalAssets()
 assert initial_loss + strategy.estimatedTotalAssets() == amount

 # lets do few harvests and see if we can manage to turn the lose to profit
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
