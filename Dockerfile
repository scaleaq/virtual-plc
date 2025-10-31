FROM codesyscontrol_virtuallinux:4.17.0.0 AS base
WORKDIR /app
# --- Install .NET 8 ASP.NET Core Runtime ---
RUN apt-get update && \
    apt-get install -y wget ca-certificates libicu-dev && \
    wget https://dotnet.microsoft.com/download/dotnet/scripts/v1/dotnet-install.sh && \
    chmod +x dotnet-install.sh && \
    ./dotnet-install.sh --channel 8.0 --runtime aspnetcore && \
    ln -s /root/.dotnet/dotnet /usr/bin/dotnet && \
    rm dotnet-install.sh

ENTRYPOINT ["/opt/codesys/scripts/startup.sh"]
