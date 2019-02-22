module Pipeline.Pipeline exposing
    ( Flags
    , Model
    , changeToPipelineAndGroups
    , getUpdateMessage
    , handleCallback
    , init
    , subscriptions
    , update
    , view
    )

import Callback exposing (Callback(..))
import Char
import Colors
import Concourse
import Concourse.Cli as Cli
import Effects exposing (Effect(..))
import Html exposing (Html)
import Html.Attributes
    exposing
        ( class
        , height
        , href
        , id
        , src
        , width
        )
import Html.Attributes.Aria exposing (ariaLabel)
import Html.Styled as HS
import Http
import Json.Decode
import Json.Encode
import Pipeline.Msgs exposing (Msg(..))
import Pipeline.Styles as Styles
import RemoteData exposing (..)
import Routes
import StrictEvents exposing (onLeftClickOrShiftLeftClick)
import Subscription exposing (Subscription(..))
import Svg exposing (..)
import Svg.Attributes as SvgAttributes
import Time exposing (Time)
import TopBar.Model
import TopBar.Styles
import TopBar.TopBar as TopBar
import UpdateMsg exposing (UpdateMsg)
import UserState exposing (UserState)


type alias Model =
    { pipelineLocator : Concourse.PipelineIdentifier
    , pipeline : WebData Concourse.Pipeline
    , fetchedJobs : Maybe Json.Encode.Value
    , fetchedResources : Maybe Json.Encode.Value
    , renderedJobs : Maybe Json.Encode.Value
    , renderedResources : Maybe Json.Encode.Value
    , concourseVersion : String
    , turbulenceImgSrc : String
    , experiencingTurbulence : Bool
    , selectedGroups : List String
    , hideLegend : Bool
    , hideLegendCounter : Time
    , topBar : TopBar.Model.Model
    }


type alias Flags =
    { pipelineLocator : Concourse.PipelineIdentifier
    , turbulenceImgSrc : String
    , selectedGroups : List String
    }


init : Flags -> ( Model, List Effect )
init flags =
    let
        ( topBar, topBarEffects ) =
            TopBar.init { route = Routes.Pipeline { id = flags.pipelineLocator, groups = flags.selectedGroups } }

        model =
            { concourseVersion = ""
            , turbulenceImgSrc = flags.turbulenceImgSrc
            , pipelineLocator = flags.pipelineLocator
            , pipeline = RemoteData.NotAsked
            , fetchedJobs = Nothing
            , fetchedResources = Nothing
            , renderedJobs = Nothing
            , renderedResources = Nothing
            , experiencingTurbulence = False
            , hideLegend = False
            , hideLegendCounter = 0
            , selectedGroups = flags.selectedGroups
            , topBar = topBar
            }
    in
    ( model, [ FetchPipeline flags.pipelineLocator, FetchVersion, ResetPipelineFocus ] ++ topBarEffects )


changeToPipelineAndGroups : Flags -> Model -> ( Model, List Effect )
changeToPipelineAndGroups flags model =
    if model.pipelineLocator == flags.pipelineLocator then
        let
            ( newModel, effects ) =
                renderIfNeeded { model | selectedGroups = flags.selectedGroups }
        in
        ( newModel, effects ++ [ ResetPipelineFocus ] )

    else
        init flags


loadPipeline : Concourse.PipelineIdentifier -> Model -> ( Model, List Effect )
loadPipeline pipelineLocator model =
    ( { model | pipelineLocator = pipelineLocator }
    , [ FetchPipeline pipelineLocator, FetchVersion, ResetPipelineFocus ]
    )


timeUntilHidden : Time
timeUntilHidden =
    10 * Time.second


timeUntilHiddenCheckInterval : Time
timeUntilHiddenCheckInterval =
    1 * Time.second


getUpdateMessage : Model -> UpdateMsg
getUpdateMessage model =
    case model.pipeline of
        RemoteData.Failure _ ->
            UpdateMsg.NotFound

        _ ->
            UpdateMsg.AOK


handleCallback : Callback -> Model -> ( Model, List Effect )
handleCallback msg model =
    let
        ( newTopBar, topBarEffects ) =
            TopBar.handleCallback msg model.topBar

        ( newModel, pipelineEffects ) =
            handleCallbackWithoutTopBar msg model
    in
    ( { newModel | topBar = newTopBar }
    , topBarEffects ++ pipelineEffects
    )


handleCallbackWithoutTopBar : Callback -> Model -> ( Model, List Effect )
handleCallbackWithoutTopBar callback model =
    let
        redirectToLoginIfUnauthenticated status =
            if status.code == 401 then
                [ RedirectToLogin ]

            else
                []
    in
    case callback of
        PipelineFetched (Ok pipeline) ->
            ( { model | pipeline = RemoteData.Success pipeline }
            , [ FetchJobs model.pipelineLocator
              , FetchResources model.pipelineLocator
              , SetTitle <| pipeline.name ++ " - "
              ]
            )

        PipelineFetched (Err err) ->
            case err of
                Http.BadStatus { status } ->
                    if status.code == 404 then
                        ( { model | pipeline = RemoteData.Failure err }, [] )

                    else
                        ( model, redirectToLoginIfUnauthenticated status )

                _ ->
                    renderIfNeeded { model | experiencingTurbulence = True }

        JobsFetched (Ok fetchedJobs) ->
            renderIfNeeded { model | fetchedJobs = Just fetchedJobs, experiencingTurbulence = False }

        JobsFetched (Err err) ->
            case err of
                Http.BadStatus { status } ->
                    ( model, redirectToLoginIfUnauthenticated status )

                _ ->
                    renderIfNeeded { model | fetchedJobs = Nothing, experiencingTurbulence = True }

        ResourcesFetched (Ok fetchedResources) ->
            renderIfNeeded { model | fetchedResources = Just fetchedResources, experiencingTurbulence = False }

        ResourcesFetched (Err err) ->
            case err of
                Http.BadStatus { status } ->
                    ( model, redirectToLoginIfUnauthenticated status )

                _ ->
                    renderIfNeeded { model | fetchedResources = Nothing, experiencingTurbulence = True }

        VersionFetched (Ok version) ->
            ( { model | concourseVersion = version, experiencingTurbulence = False }, [] )

        VersionFetched (Err err) ->
            flip always (Debug.log "failed to fetch version" err) <|
                ( { model | experiencingTurbulence = True }, [] )

        _ ->
            ( model, [] )


update : Msg -> Model -> ( Model, List Effect )
update msg model =
    case msg of
        HideLegendTimerTicked _ ->
            if model.hideLegendCounter + timeUntilHiddenCheckInterval > timeUntilHidden then
                ( { model | hideLegend = True }, [] )

            else
                ( { model | hideLegendCounter = model.hideLegendCounter + timeUntilHiddenCheckInterval }
                , []
                )

        ShowLegend ->
            ( { model | hideLegend = False, hideLegendCounter = 0 }, [] )

        KeyPressed keycode ->
            ( { model | hideLegend = False, hideLegendCounter = 0 }
            , if (Char.fromCode keycode |> Char.toLower) == 'f' then
                [ ResetPipelineFocus ]

              else
                []
            )

        AutoupdateTimerTicked timestamp ->
            ( model, [ FetchPipeline model.pipelineLocator ] )

        PipelineIdentifierFetched pipelineIdentifier ->
            ( model, [ FetchPipeline pipelineIdentifier ] )

        AutoupdateVersionTicked _ ->
            ( model, [ FetchVersion ] )

        ToggleGroup group ->
            ( model, [ NavigateTo <| getNextUrl (toggleGroup group model.selectedGroups model.pipeline) model ] )

        SetGroups groups ->
            ( model, [ NavigateTo <| getNextUrl groups model ] )

        FromTopBar msg ->
            let
                ( newTopBar, topBarEffects ) =
                    TopBar.update msg model.topBar
            in
            ( { model | topBar = newTopBar }, topBarEffects )


getPinnedResources : Model -> List ( String, Concourse.Version )
getPinnedResources model =
    case model.fetchedResources of
        Nothing ->
            []

        Just res ->
            Json.Decode.decodeValue (Json.Decode.list Concourse.decodeResource) res
                |> Result.withDefault []
                |> List.filterMap (\r -> Maybe.map (\v -> ( r.name, v )) r.pinnedVersion)


subscriptions : Model -> List (Subscription Msg)
subscriptions model =
    [ OnClockTick (1 * Time.minute) AutoupdateVersionTicked
    , OnClockTick (5 * Time.second) AutoupdateTimerTicked
    , OnClockTick timeUntilHiddenCheckInterval HideLegendTimerTicked
    , OnMouseMove ShowLegend
    , OnMouseClick ShowLegend
    , OnKeyDown
    ]


view : UserState -> Model -> Html Msg
view userState model =
    let
        pipelineState =
            TopBar.Model.HasPipeline
                { pinnedResources = getPinnedResources model
                , pipeline = model.pipelineLocator
                , isPaused = isPaused model.pipeline
                }
    in
    Html.div [ Html.Attributes.style [ ( "height", "100%" ) ] ]
        [ Html.div
            [ Html.Attributes.style TopBar.Styles.pageIncludingTopBar, id "page-including-top-bar" ]
            [ Html.map FromTopBar <| HS.toUnstyled <| TopBar.view userState pipelineState model.topBar
            , Html.div
                [ Html.Attributes.style TopBar.Styles.pipelinePageBelowTopBar
                , id "page-below-top-bar"
                ]
                [ viewSubPage model ]
            ]
        ]


isPaused : WebData Concourse.Pipeline -> Bool
isPaused p =
    RemoteData.withDefault False (RemoteData.map .paused p)


viewSubPage : Model -> Html Msg
viewSubPage model =
    Html.div [ class "pipeline-view" ]
        [ viewGroupsBar model
        , Html.div [ class "pipeline-content" ]
            [ Svg.svg
                [ SvgAttributes.class "pipeline-graph test" ]
                []
            , Html.div
                [ if model.experiencingTurbulence then
                    class "error-message"

                  else
                    class "error-message hidden"
                ]
                [ Html.div [ class "message" ]
                    [ Html.img [ src model.turbulenceImgSrc, class "seatbelt" ] []
                    , Html.p [] [ Html.text "experiencing turbulence" ]
                    , Html.p [ class "explanation" ] []
                    ]
                ]
            , Html.dl
                [ if model.hideLegend then
                    class "legend hidden"

                  else
                    class "legend"
                ]
                [ Html.dt [ class "succeeded" ] []
                , Html.dd [] [ Html.text "succeeded" ]
                , Html.dt [ class "errored" ] []
                , Html.dd [] [ Html.text "errored" ]
                , Html.dt [ class "aborted" ] []
                , Html.dd [] [ Html.text "aborted" ]
                , Html.dt [ class "paused" ] []
                , Html.dd [] [ Html.text "paused" ]
                , Html.dt [ Html.Attributes.style [ ( "background-color", Colors.pinned ) ] ] []
                , Html.dd [] [ Html.text "pinned" ]
                , Html.dt [ class "failed" ] []
                , Html.dd [] [ Html.text "failed" ]
                , Html.dt [ class "pending" ] []
                , Html.dd [] [ Html.text "pending" ]
                , Html.dt [ class "started" ] []
                , Html.dd [] [ Html.text "started" ]
                , Html.dt [ class "dotted" ] [ Html.text "." ]
                , Html.dd [] [ Html.text "dependency" ]
                , Html.dt [ class "solid" ] [ Html.text "-" ]
                , Html.dd [] [ Html.text "dependency (trigger)" ]
                ]
            , Html.table [ class "lower-right-info" ]
                [ Html.tr []
                    [ Html.td [ class "label" ] [ Html.text "cli:" ]
                    , Html.td []
                        [ Html.ul [ class "cli-downloads" ] <|
                            List.map
                                (\cli ->
                                    Html.li []
                                        [ Html.a
                                            [ href <| Cli.downloadUrl cli
                                            , ariaLabel <| Cli.label cli
                                            , Html.Attributes.style <| cliIcon cli
                                            ]
                                            []
                                        ]
                                )
                                Cli.clis
                        ]
                    ]
                , Html.tr []
                    [ Html.td [ class "label" ] [ Html.text "version:" ]
                    , Html.td []
                        [ Html.div [ id "concourse-version" ]
                            [ Html.text "v"
                            , Html.span [ class "number" ] [ Html.text model.concourseVersion ]
                            ]
                        ]
                    ]
                ]
            ]
        ]


viewGroupsBar : Model -> Html Msg
viewGroupsBar model =
    let
        groupList =
            case model.pipeline of
                RemoteData.Success pipeline ->
                    List.map
                        (viewGroup
                            { selectedGroups = selectedGroupsOrDefault model
                            , pipelineLocator = model.pipelineLocator
                            }
                        )
                        pipeline.groups

                _ ->
                    []
    in
    if List.isEmpty groupList then
        Html.text ""

    else
        Html.nav
            [ id "groups-bar"
            , Html.Attributes.style Styles.groupsBar
            ]
            [ Html.ul
                [ Html.Attributes.style Styles.groupsList ]
                groupList
            ]


viewGroup :
    { a
        | selectedGroups : List String
        , pipelineLocator : Concourse.PipelineIdentifier
    }
    -> Concourse.PipelineGroup
    -> Html Msg
viewGroup { selectedGroups, pipelineLocator } grp =
    let
        url =
            Routes.toString <|
                Routes.Pipeline { id = pipelineLocator, groups = [] }
    in
    Html.li
        []
        [ Html.a
            [ Html.Attributes.href <| url ++ "?groups=" ++ grp.name
            , Html.Attributes.style <| Styles.groupItem <| List.member grp.name selectedGroups
            , onLeftClickOrShiftLeftClick
                (SetGroups [ grp.name ])
                (ToggleGroup grp)
            ]
            [ Html.text grp.name ]
        ]


jobAppearsInGroups : List String -> Concourse.PipelineIdentifier -> Json.Encode.Value -> Bool
jobAppearsInGroups groupNames pi jobJson =
    let
        concourseJob =
            Json.Decode.decodeValue (Concourse.decodeJob pi) jobJson
    in
    case concourseJob of
        Ok cj ->
            anyIntersect cj.groups groupNames

        Err err ->
            flip always (Debug.log "failed to check if job is in group" err) <|
                False


expandJsonList : Json.Encode.Value -> List Json.Decode.Value
expandJsonList flatList =
    let
        result =
            Json.Decode.decodeValue (Json.Decode.list Json.Decode.value) flatList
    in
    case result of
        Ok res ->
            res

        Err err ->
            []


filterJobs : Model -> Json.Encode.Value -> Json.Encode.Value
filterJobs model value =
    Json.Encode.list <|
        List.filter
            (jobAppearsInGroups (activeGroups model) model.pipelineLocator)
            (expandJsonList value)


activeGroups : Model -> List String
activeGroups model =
    case ( model.selectedGroups, model.pipeline |> RemoteData.toMaybe |> Maybe.andThen (List.head << .groups) ) of
        ( [], Just firstGroup ) ->
            [ firstGroup.name ]

        ( groups, _ ) ->
            groups


renderIfNeeded : Model -> ( Model, List Effect )
renderIfNeeded model =
    case ( model.fetchedResources, model.fetchedJobs ) of
        ( Just fetchedResources, Just fetchedJobs ) ->
            let
                filteredFetchedJobs =
                    if List.isEmpty (activeGroups model) then
                        fetchedJobs

                    else
                        filterJobs model fetchedJobs
            in
            case ( model.renderedResources, model.renderedJobs ) of
                ( Just renderedResources, Just renderedJobs ) ->
                    if
                        (expandJsonList renderedJobs /= expandJsonList filteredFetchedJobs)
                            || (expandJsonList renderedResources /= expandJsonList fetchedResources)
                    then
                        ( { model
                            | renderedJobs = Just filteredFetchedJobs
                            , renderedResources = Just fetchedResources
                          }
                        , [ RenderPipeline filteredFetchedJobs fetchedResources ]
                        )

                    else
                        ( model, [] )

                _ ->
                    ( { model
                        | renderedJobs = Just filteredFetchedJobs
                        , renderedResources = Just fetchedResources
                      }
                    , [ RenderPipeline filteredFetchedJobs fetchedResources ]
                    )

        _ ->
            ( model, [] )


anyIntersect : List a -> List a -> Bool
anyIntersect list1 list2 =
    case list1 of
        [] ->
            False

        first :: rest ->
            if List.member first list2 then
                True

            else
                anyIntersect rest list2


toggleGroup : Concourse.PipelineGroup -> List String -> WebData Concourse.Pipeline -> List String
toggleGroup grp names mpipeline =
    if List.member grp.name names then
        List.filter ((/=) grp.name) names

    else if List.isEmpty names then
        grp.name :: getDefaultSelectedGroups mpipeline

    else
        grp.name :: names


selectedGroupsOrDefault : Model -> List String
selectedGroupsOrDefault model =
    if List.isEmpty model.selectedGroups then
        getDefaultSelectedGroups model.pipeline

    else
        model.selectedGroups


getDefaultSelectedGroups : WebData Concourse.Pipeline -> List String
getDefaultSelectedGroups pipeline =
    case pipeline of
        RemoteData.Success pipeline ->
            case List.head pipeline.groups of
                Nothing ->
                    []

                Just first ->
                    [ first.name ]

        _ ->
            []


getNextUrl : List String -> Model -> String
getNextUrl newGroups model =
    Routes.toString <|
        Routes.Pipeline { id = model.pipelineLocator, groups = newGroups }


cliIcon : Cli.Cli -> List ( String, String )
cliIcon cli =
    [ ( "width", "12px" )
    , ( "height", "12px" )
    , ( "background-image", Cli.iconUrl cli )
    , ( "background-repeat", "no-repeat" )
    , ( "background-position", "50% 50%" )
    , ( "background-size", "contain" )
    , ( "display", "inline-block" )
    ]
