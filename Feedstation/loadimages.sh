for i in `ls *.tar`; do 
    docker load -i $i; 
done