#!/bin/sh

i=$1

mkdir -p logs

stack exec -- pos-wallet submit -i $i --peer '127.0.0.1:2000/ABOtPlQMv123_4wzfgjAzvsT2LE='\
  | tee logs/wallet-$i-`date '+%F_%H%M%S'`.log