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
 oracle = Contract("0x8a887282E67ff41d36C0b7537eAB035291461AcD")
 reth2 = Contract("0x20BC832ca081b91433ff6c17f85701B6e92486c5")

 token.approve(vault.address, amount, {"from": user})
 vault.deposit(amount, {"from": user})
 assert token.balanceOf(vault.address) == amount

 strategy.harvest()
 chain.sleep(1)
 chain.mine(1)
 assert strategy.estimatedTotalAssets() >= amount
 print("strategy has", strategy.estimatedTotalAssets())

 reth2.updateTotalRewards(1800000000000000000000,{"from":oracle})
 chain.sleep(86400 * 5)
 chain.mine(1)
 tx = strategy.harvest()   # harvest 1 time to get some profit

 checks.check_harvest_profitable(tx) # if we made profit

 vault.withdraw(vault.balanceOf(user),user,10_000,{"from":user})

 loss = amount - token.balanceOf(user)
 assert token.balanceOf(user) < amount
 assert token.balanceOf(user) + loss ==  amount

def test_fullwithdrawal_withoutharvest(
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
  user_balance_before = token.balanceOf(user) # what user had initially
  token.approve(vault.address, amount, {"from": user})
  vault.deposit(amount, {"from": user})
  assert token.balanceOf(vault.address) == amount #70

  strategy.harvest() # send funds to strategy
  chain.sleep(1)
  chain.mine(1)
  assert strategy.estimatedTotalAssets() >= amount
  print("strategy has", strategy.estimatedTotalAssets())

  vault.withdraw(vault.balanceOf(user),user,10_000,{"from":user})  # withdraw and accept loss
  loss = user_balance_before - token.balanceOf(user) # how much user lost
  print(loss)
  print(token.balanceOf(user))
  print(strategy.estimatedTotalAssets())
  checks.check_vault_empty(vault)
  assert loss + token.balanceOf(user) == user_balance_before
