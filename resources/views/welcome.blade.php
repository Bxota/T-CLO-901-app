<html>
    <head>
    <title>Hello world sample app{{ config('app.deploy_env') !== 'production' ? ' [' . strtoupper(config('app.deploy_env')) . ']' : '' }}</title>
    <script
        src="https://code.jquery.com/jquery-3.7.0.min.js"
        integrity="sha256-2Pmvv0kuTBOenSvLm6bvfBSSHrUJ+3A7x6P5Ebd07/g="
        crossorigin="anonymous"></script>
    <style>
        #env-banner {
            background: #e67e22;
            color: #fff;
            font: bold 1rem sans-serif;
            letter-spacing: .2em;
            text-align: center;
            padding: .5rem;
            margin: -8px -8px 1rem;
        }
        #deploy-info {
            color: #666;
            font: .8rem sans-serif;
            margin-top: 2rem;
        }
    </style>
    </head>
    <body>
        @if (config('app.deploy_env') !== 'production')
        <div id="env-banner">{{ strtoupper(config('app.deploy_env')) }}</div>
        @endif
        <h1>Hello world sample app</h1>
        <p>Counter :<p id="value">{{ $value }}</p></p>
        <button id="add">+1</button>

        <p id="deploy-info">version {{ config('app.version') }} &middot; {{ config('app.deploy_env') }}</p>

        <script>
            $(document).ready(function(){
                $("#add").click(function(e){
                    $.get("/api/counter/add", function(data){
                        $('#value').text(data.value);
                    });
                });
            });
        </script>
    </body>
</html>
