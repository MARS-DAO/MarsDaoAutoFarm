#!/bin/bash
truffle migrate --reset --network $1
echo "please wait...60 sec"
sleep 60

#truffle run verify StratX --network $1
truffle run verify BStratX --network $1

echo "done"