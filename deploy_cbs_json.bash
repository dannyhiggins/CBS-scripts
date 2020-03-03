#!/bin/bash
LOG=~/remove_cbs_stop_apps.log
logme ()
{
echo "`date`: ${*}" | tee -a ${LOG}
}
logme "Deploying CBS from scripted process on `hostname`"
aws servicecatalog provision-product --cli-input-json file://cbs.json | tee -a $LOG
